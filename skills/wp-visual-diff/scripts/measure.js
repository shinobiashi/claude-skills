#!/usr/bin/env node
// measure.js — Render pages with Playwright and record, for each page and width: the HTTP
// status, whether WordPress served its 404 template, every <img> box (after scrolling so
// lazy images load), images that failed to load, the document height, a fingerprint of the
// <img> attributes and of the CSS, and a full-page screenshot. compare.py diffs two runs.
//
// Usage:
//   node measure.js --base http://localhost:8881 --page top=/ --page shop=/shop/ \
//     [--width 1280 --width 390] --label before --out DIR \
//     [--dpr 1] [--settle 1500] [--no-cache-bust] [--playwright /path/to/node_modules/playwright]
//
// Playwright is looked up in this order: --playwright, $PLAYWRIGHT_PATH, a normal require
// ('playwright', 'playwright-core', '@playwright/test'), then ~/Dev/*/node_modules/playwright.
// Writes DIR/layout-<label>.json and DIR/shot-<label>-<page>-<width>.png. Exit 2 when
// Playwright cannot be loaded or a page cannot be opened; page problems (404, broken images)
// are recorded and reported by compare.py instead.
'use strict';

const fs = require( 'fs' );
const os = require( 'os' );
const path = require( 'path' );
const crypto = require( 'crypto' );

function parseArgs( argv ) {
	const o = { pages: [], widths: [], dpr: 1, settle: 1500, cacheBust: true, playwright: null, base: null, label: null, out: null };
	for ( let i = 0; i < argv.length; i++ ) {
		const a = argv[ i ];
		const next = () => {
			if ( i + 1 >= argv.length ) {
				throw new Error( `${ a } needs a value` );
			}
			return argv[ ++i ];
		};
		if ( a === '--base' ) o.base = next().replace( /\/+$/, '' );
		else if ( a === '--page' ) {
			const v = next();
			const eq = v.indexOf( '=' );
			if ( eq < 1 ) throw new Error( `--page wants name=/path, got ${ v }` );
			o.pages.push( [ v.slice( 0, eq ), v.slice( eq + 1 ) ] );
		} else if ( a === '--width' ) o.widths.push( parseInt( next(), 10 ) );
		else if ( a === '--label' ) o.label = next();
		else if ( a === '--out' ) o.out = next();
		else if ( a === '--dpr' ) o.dpr = parseFloat( next() );
		else if ( a === '--settle' ) o.settle = parseInt( next(), 10 );
		else if ( a === '--no-cache-bust' ) o.cacheBust = false;
		else if ( a === '--playwright' ) o.playwright = next();
		else if ( a === '-h' || a === '--help' ) {
			process.stdout.write( fs.readFileSync( __filename, 'utf8' ).split( '\n' ).slice( 1, 18 ).join( '\n' ) + '\n' );
			process.exit( 0 );
		} else throw new Error( `unknown argument ${ a }` );
	}
	if ( ! o.base || ! o.label || ! o.out || ! o.pages.length ) {
		throw new Error( '--base, --label, --out and at least one --page are required' );
	}
	if ( ! /^[A-Za-z0-9._-]+$/.test( o.label ) ) throw new Error( '--label may only contain letters, digits, . _ -' );
	if ( ! o.widths.length ) o.widths = [ 1280, 390 ];
	return o;
}

function loadPlaywright( explicit ) {
	const tries = [];
	if ( explicit ) tries.push( path.resolve( explicit ) );
	if ( process.env.PLAYWRIGHT_PATH ) tries.push( path.resolve( process.env.PLAYWRIGHT_PATH ) );
	tries.push( 'playwright', 'playwright-core', '@playwright/test' );
	const dev = path.join( os.homedir(), 'Dev' );
	try {
		for ( const d of fs.readdirSync( dev ).sort() ) {
			tries.push( path.join( dev, d, 'node_modules', 'playwright' ) );
		}
	} catch ( e ) {
		// No ~/Dev: nothing more to try.
	}
	for ( const t of tries ) {
		try {
			const m = require( t );
			if ( m && m.chromium ) return { chromium: m.chromium, from: t };
		} catch ( e ) {
			// Try the next one.
		}
	}
	throw new Error( 'Playwright not found. Pass --playwright <path to node_modules/playwright>, set PLAYWRIGHT_PATH, or install it (npm i -D playwright && npx playwright install chromium).' );
}

const sha1 = ( s ) => crypto.createHash( 'sha1' ).update( s ).digest( 'hex' ).slice( 0, 16 );

async function measurePage( page, url, settle ) {
	const resp = await page.goto( url, { waitUntil: 'load', timeout: 60000 } );
	await page.waitForTimeout( settle );
	const data = await page.evaluate( async () => {
		const sleep = ( ms ) => new Promise( ( r ) => setTimeout( r, ms ) );
		for ( let y = 0; y < document.documentElement.scrollHeight; y += 300 ) {
			window.scrollTo( 0, y );
			await sleep( 60 );
		}
		window.scrollTo( 0, document.documentElement.scrollHeight );
		await sleep( 500 );
		await Promise.race( [
			Promise.all( [ ...document.images ].map( ( img ) => ( img.complete ? null : new Promise( ( r ) => {
				img.addEventListener( 'load', r );
				img.addEventListener( 'error', r );
			} ) ) ) ),
			sleep( 15000 ),
		] );
		if ( document.fonts && document.fonts.ready ) await document.fonts.ready;
		window.scrollTo( 0, 0 );
		await sleep( 200 );
		const round = ( n ) => Math.round( n * 10 ) / 10;
		const base = ( u ) => ( u || '' ).split( '?' )[ 0 ].split( '/' ).pop().slice( 0, 80 );
		const imgs = [ ...document.images ].map( ( img ) => {
			const r = img.getBoundingClientRect();
			const attrs = [ ...img.attributes ].map( ( a ) => `${ a.name }=${ a.value }` ).sort().join( ' ' );
			return {
				src: base( img.getAttribute( 'src' ) ),
				current: base( img.currentSrc ),
				w: round( r.width ), h: round( r.height ),
				x: round( r.left + window.scrollX ), y: round( r.top + window.scrollY ),
				loaded: img.complete && img.naturalWidth > 0,
				attrs,
			};
		} );
		const css = [
			...[ ...document.querySelectorAll( 'link[rel~="stylesheet"]' ) ].map( ( l ) => l.getAttribute( 'href' ) || '' ),
			...[ ...document.querySelectorAll( 'style' ) ].map( ( s ) => s.textContent ),
		].join( '\n' );
		return {
			height: document.documentElement.scrollHeight,
			error404: document.body.classList.contains( 'error404' ),
			title: document.title.slice( 0, 80 ),
			imgs,
			css,
		};
	} );
	const broken = data.imgs.filter( ( i ) => ! i.loaded ).map( ( i ) => i.src );
	return {
		url,
		status: resp ? resp.status() : null,
		finalPath: new URL( page.url() ).pathname,
		error404: data.error404,
		title: data.title,
		height: data.height,
		broken,
		fingerprint: { imgs: sha1( data.imgs.map( ( i ) => i.attrs ).join( '\n' ) ), css: sha1( data.css ) },
		imgs: data.imgs.map( ( { attrs, ...rest } ) => rest ),
	};
}

( async () => {
	let o;
	let pw;
	try {
		o = parseArgs( process.argv.slice( 2 ) );
		pw = loadPlaywright( o.playwright );
	} catch ( e ) {
		console.error( `measure.js: ${ e.message }` );
		process.exit( 2 );
	}
	fs.mkdirSync( o.out, { recursive: true } );
	const outDir = path.resolve( o.out );
	let browser;
	try {
		browser = await pw.chromium.launch();
	} catch ( e ) {
		console.error( `measure.js: cannot start Chromium (${ e.message.split( '\n' )[ 0 ] }). Run: npx playwright install chromium` );
		process.exit( 2 );
	}
	const result = { label: o.label, base: o.base, dpr: o.dpr, playwright: pw.from, measuredAt: new Date().toISOString(), pages: {} };
	let failed = false;
	try {
		for ( const width of o.widths ) {
			const context = await browser.newContext( { viewport: { width, height: 900 }, deviceScaleFactor: o.dpr } );
			const page = await context.newPage();
			for ( const [ name, p ] of o.pages ) {
				const u = new URL( o.base + ( p.startsWith( '/' ) ? p : `/${ p }` ) );
				if ( o.cacheBust ) u.searchParams.set( 'vdiff', `${ o.label }-${ Date.now() }` );
				const key = `${ name }@${ width }`;
				try {
					const m = await measurePage( page, u.toString(), o.settle );
					m.screenshot = path.join( outDir, `shot-${ o.label }-${ name }-${ width }.png` );
					await page.screenshot( { path: m.screenshot, fullPage: true } );
					result.pages[ key ] = m;
					const warn = [];
					if ( ! m.status || m.status >= 400 ) warn.push( `HTTP ${ m.status }` );
					if ( m.error404 ) warn.push( 'WordPress 404 template' );
					if ( m.broken.length ) warn.push( `${ m.broken.length } image(s) did not load` );
					console.log( `${ key }\tstatus ${ m.status }\theight ${ m.height }\timgs ${ m.imgs.length }${ warn.length ? `\tWARN: ${ warn.join( ', ' ) }` : '' }` );
				} catch ( e ) {
					console.error( `measure.js: ${ key } could not be measured: ${ e.message.split( '\n' )[ 0 ] }` );
					failed = true;
				}
			}
			await context.close();
		}
	} finally {
		await browser.close();
	}
	const file = path.join( outDir, `layout-${ o.label }.json` );
	fs.writeFileSync( file, JSON.stringify( result, null, 1 ) );
	console.log( `wrote ${ file }` );
	process.exit( failed ? 2 : 0 );
} )();
