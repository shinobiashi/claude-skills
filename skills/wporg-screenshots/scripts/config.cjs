// config.cjs — read and validate a project's wporg-screenshots config (<config dir>/shots.json).
//
//   node config.cjs check <shots.json>             validate; print the shell view below
//   node config.cjs vars <setup output> <out.json> turn the KEY=value lines a setup hook printed into JSON
//
// The shell view is one KEY=value per line; list items repeat the key. Every value is validated
// to hold no newline, so capture.sh can read it with `while IFS= read -r`.
//   PLUGIN_DIR=plugins/my-plugin      FORMAT=png       USER=1      LOCALE=en_US
//   PERMALINK=/%postname%/            SHOTS=5
//   BUILD_ARG=npm  BUILD_ARG=run  BUILD_ARG=build   (argv, no shell)
//   DEACTIVATE=<slug>  ACTIVATE=<slug>  SETUP_ARG=<value>
// Anything unexpected is an error (exit 2): a typo in a key must not be ignored silently.
'use strict';

const fs = require( 'fs' );

function fail( message ) {
	console.error( `config: ${ message }` );
	process.exit( 2 );
}

const KNOWN = [
	'plugin_dir', 'build', 'deactivate', 'activate', 'permalink', 'user', 'locale', 'setup_args',
	'format', 'viewport', 'local_storage', 'error_selector', 'shots',
];
const SHOT_KNOWN = [ 'path', 'wait_for', 'uncheck', 'name' ];
const SLUG = /^[a-z0-9][a-z0-9_.-]*$/;

function line( value, what ) {
	if ( 'string' !== typeof value || /[\r\n\0]/.test( value ) ) {
		fail( `${ what } must be a single-line string` );
	}
	return value;
}

function strings( value, what ) {
	if ( undefined === value ) {
		return [];
	}
	if ( ! Array.isArray( value ) ) {
		fail( `${ what } must be an array of strings` );
	}
	return value.map( ( v, i ) => line( v, `${ what }[${ i }]` ) );
}

function check( file ) {
	let config;
	try {
		config = JSON.parse( fs.readFileSync( file, 'utf8' ) );
	} catch ( e ) {
		fail( `cannot read ${ file }: ${ e.message }` );
	}
	if ( null === config || 'object' !== typeof config || Array.isArray( config ) ) {
		fail( `${ file } must hold a JSON object` );
	}
	for ( const key of Object.keys( config ) ) {
		if ( ! KNOWN.includes( key ) ) {
			fail( `unknown key "${ key }" in ${ file } (known: ${ KNOWN.join( ', ' ) })` );
		}
	}

	const out = [];
	const pluginDir = undefined === config.plugin_dir ? '.' : line( config.plugin_dir, 'plugin_dir' ).replace( /\/+$/, '' ) || '.';
	if ( pluginDir.startsWith( '/' ) || pluginDir.split( '/' ).includes( '..' ) ) {
		fail( 'plugin_dir must be a path inside the repository (no leading / and no ..)' );
	}
	out.push( `PLUGIN_DIR=${ pluginDir }` );

	const format = undefined === config.format ? 'png' : config.format;
	if ( ! [ 'png', 'jpg' ].includes( format ) ) {
		fail( 'format must be "png" or "jpg"' );
	}
	out.push( `FORMAT=${ format }` );

	const user = undefined === config.user ? 1 : config.user;
	if ( ! Number.isInteger( user ) || user < 1 ) {
		fail( 'user must be a positive integer (the user the screenshots are taken as)' );
	}
	out.push( `USER=${ user }` );

	const locale = undefined === config.locale ? 'en_US' : line( config.locale, 'locale' );
	if ( '' !== locale && ! /^[a-z]{2,3}(_[A-Z]{2})?(_[a-z0-9]+)?$/.test( locale ) ) {
		fail( `locale "${ locale }" is not a WordPress locale (e.g. en_US; "" leaves the user's locale alone)` );
	}
	out.push( `LOCALE=${ locale }` );

	if ( undefined !== config.permalink ) {
		out.push( `PERMALINK=${ line( config.permalink, 'permalink' ) }` );
	}

	for ( const arg of strings( config.build, 'build' ) ) {
		out.push( `BUILD_ARG=${ arg }` );
	}
	for ( const [ key, list ] of [ [ 'DEACTIVATE', 'deactivate' ], [ 'ACTIVATE', 'activate' ] ] ) {
		for ( const slug of strings( config[ list ], list ) ) {
			if ( ! SLUG.test( slug ) ) {
				fail( `${ list }: "${ slug }" is not a plugin slug` );
			}
			out.push( `${ key }=${ slug }` );
		}
	}
	for ( const arg of strings( config.setup_args, 'setup_args' ) ) {
		out.push( `SETUP_ARG=${ arg }` );
	}

	if ( undefined !== config.viewport ) {
		const v = config.viewport;
		if ( null === v || 'object' !== typeof v || ! Number.isInteger( v.width ) || ! Number.isInteger( v.height ) || v.width < 320 || v.height < 320 ) {
			fail( 'viewport must be { "width": <int ≥ 320>, "height": <int ≥ 320> }' );
		}
	}
	if ( undefined !== config.local_storage ) {
		const ls = config.local_storage;
		if ( null === ls || 'object' !== typeof ls || Array.isArray( ls ) ) {
			fail( 'local_storage must be an object of string values' );
		}
		for ( const [ k, v ] of Object.entries( ls ) ) {
			line( v, `local_storage.${ k }` );
		}
	}
	if ( undefined !== config.error_selector ) {
		line( config.error_selector, 'error_selector' );
	}

	if ( ! Array.isArray( config.shots ) || 0 === config.shots.length ) {
		fail( 'shots must be a non-empty array' );
	}
	config.shots.forEach( ( shot, i ) => {
		if ( null === shot || 'object' !== typeof shot || Array.isArray( shot ) ) {
			fail( `shots[${ i }] must be an object` );
		}
		for ( const key of Object.keys( shot ) ) {
			if ( ! SHOT_KNOWN.includes( key ) ) {
				fail( `unknown key "${ key }" in shots[${ i }] (known: ${ SHOT_KNOWN.join( ', ' ) })` );
			}
		}
		if ( ! line( shot.path, `shots[${ i }].path` ).startsWith( '/' ) ) {
			fail( `shots[${ i }].path must start with / (it is joined to the tests site URL)` );
		}
		if ( '' === line( shot.wait_for, `shots[${ i }].wait_for` ).trim() ) {
			fail( `shots[${ i }].wait_for must not be empty (the text that shows the screen has finished rendering)` );
		}
		strings( shot.uncheck, `shots[${ i }].uncheck` );
		if ( undefined !== shot.name ) {
			line( shot.name, `shots[${ i }].name` );
		}
	} );
	out.push( `SHOTS=${ config.shots.length }` );

	process.stdout.write( out.join( '\n' ) + '\n' );
}

// KEY=value lines (KEY in capitals) of a setup hook's output, COOKIES excluded, as a JSON object.
function vars( input, output ) {
	const result = {};
	for ( const raw of fs.readFileSync( input, 'utf8' ).split( '\n' ) ) {
		const m = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec( raw );
		if ( m && 'COOKIES' !== m[ 1 ] ) {
			result[ m[ 1 ] ] = m[ 2 ];
		}
	}
	fs.writeFileSync( output, JSON.stringify( result ) );
}

const [ cmd, ...args ] = process.argv.slice( 2 );
if ( 'check' === cmd && 1 === args.length ) {
	check( args[ 0 ] );
} else if ( 'vars' === cmd && 2 === args.length ) {
	vars( args[ 0 ], args[ 1 ] );
} else {
	fail( 'usage: node config.cjs check <shots.json> | vars <setup output> <out.json>' );
}
