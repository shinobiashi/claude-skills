// shoot.cjs — take the wordpress.org screenshots (called by capture.sh; see ../SKILL.md).
//
//   node shoot.cjs <tests site URL> <cookies.json> <shots.json> <vars.json> <out dir>
//
// shots[i] of shots.json becomes screenshot-(i+1).<format>. {KEY} in a shot's path and in the
// local_storage values is replaced by the KEY=value a setup hook printed (vars.json); an unknown
// {KEY} is an error. A screen that shows an error notice is not taken: the run fails instead.
// Playwright is resolved from the project (the current directory), not from this skill.
'use strict';

const fs = require( 'fs' );
const path = require( 'path' );

const DEFAULT_VIEWPORT = { width: 1280, height: 900 };
const DEFAULT_ERROR_SELECTOR = '.notice-error, .components-notice.is-error';

function fail( message, code = 1 ) {
	console.error( `shoot: ${ message }` );
	process.exit( code );
}

const [ baseUrl, cookiesFile, shotsFile, varsFile, outDir ] = process.argv.slice( 2 );
if ( ! baseUrl || ! cookiesFile || ! shotsFile || ! varsFile || ! outDir ) {
	fail( 'usage: node shoot.cjs <base-url> <cookies.json> <shots.json> <vars.json> <out-dir>', 2 );
}
if ( ! fs.existsSync( outDir ) || ! fs.statSync( outDir ).isDirectory() ) {
	fail( `output directory does not exist: ${ outDir }`, 2 );
}

const config = JSON.parse( fs.readFileSync( shotsFile, 'utf8' ) );
const vars = JSON.parse( fs.readFileSync( varsFile, 'utf8' ) );
const viewport = config.viewport ?? DEFAULT_VIEWPORT;
const format = config.format ?? 'png';
const errorSelector = config.error_selector ?? DEFAULT_ERROR_SELECTOR;

function fill( text, what ) {
	return text.replace( /\{([A-Z][A-Z0-9_]*)\}/g, ( whole, key ) => {
		if ( ! Object.prototype.hasOwnProperty.call( vars, key ) ) {
			fail( `${ what } uses {${ key }}, but the setup hook did not print ${ key }=`, 2 );
		}
		return vars[ key ];
	} );
}

const localStorage = Object.entries( config.local_storage ?? {} ).map( ( [ k, v ] ) => [ k, fill( v, `local_storage.${ k }` ) ] );
const shots = config.shots.map( ( shot, i ) => ( { ...shot, url: baseUrl + fill( shot.path, `shots[${ i }].path` ) } ) );

let chromium;
try {
	( { chromium } = require( require.resolve( 'playwright', { paths: [ process.cwd() ] } ) ) );
} catch ( e ) {
	fail( `playwright is not installed under ${ process.cwd() }/node_modules: ${ e.message }`, 2 );
}

const host = new URL( baseUrl ).hostname;
const cookies = JSON.parse( fs.readFileSync( cookiesFile, 'utf8' ) ).map( ( c ) => ( {
	name: c.name,
	value: c.value,
	domain: host,
	path: c.path,
	httpOnly: true,
	secure: false,
	sameSite: 'Lax',
} ) );

( async () => {
	// The installed Google Chrome by default; WPORG_SHOTS_CHANNEL= (empty) uses Playwright's own Chromium.
	const channel = process.env.WPORG_SHOTS_CHANNEL ?? 'chrome';
	const browser = await chromium.launch( { headless: true, ...( channel ? { channel } : {} ) } );
	try {
		const context = await browser.newContext( { viewport, deviceScaleFactor: 1, locale: 'en-US' } );
		await context.addCookies( cookies );
		if ( localStorage.length > 0 ) {
			await context.addInitScript( ( entries ) => {
				try {
					for ( const [ k, v ] of entries ) {
						window.localStorage.setItem( k, v );
					}
				} catch ( e ) {}
			}, localStorage );
		}
		const page = await context.newPage();

		for ( const [ i, shot ] of shots.entries() ) {
			const file = path.join( outDir, `screenshot-${ i + 1 }.${ format }` );
			const label = shot.name ?? shot.path;
			// Moving to a URL that differs only in its hash does not reload a single-page admin
			// screen, so reload after every move.
			await page.goto( shot.url );
			await page.reload();
			if ( page.url().includes( 'wp-login.php' ) ) {
				throw new Error( 'the login cookies were not accepted (redirected to wp-login.php)' );
			}
			await page.getByText( shot.wait_for, { exact: false } ).first().waitFor( { timeout: 30000 } );
			await page.waitForLoadState( 'networkidle' );

			for ( const name of shot.uncheck ?? [] ) {
				const box = page.getByRole( 'checkbox', { name, exact: true } );
				if ( await box.isChecked() ) {
					await box.uncheck();
				}
			}

			// No focus ring, no hover state.
			await page.evaluate( () => document.activeElement && document.activeElement.blur() );
			await page.mouse.move( viewport.width - 10, viewport.height - 10 );
			await page.waitForTimeout( 800 );

			// Checked right before the shot, so a notice drawn late (after an uncheck) is caught too.
			const errors = await page.locator( errorSelector ).allInnerTexts();
			if ( errors.length > 0 ) {
				throw new Error( `${ label } shows an error notice: ${ errors.join( ' | ' ).slice( 0, 300 ) }` );
			}
			await page.screenshot( { path: file, fullPage: true, ...( 'jpg' === format ? { type: 'jpeg', quality: 90 } : {} ) } );
			console.log( `shot ${ path.basename( file ) } (${ label })` );
		}
	} finally {
		await browser.close();
	}
} )().catch( ( e ) => fail( e.stack || String( e ) ) );
