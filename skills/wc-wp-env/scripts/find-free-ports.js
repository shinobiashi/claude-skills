#!/usr/bin/env node
/*
 * find-free-ports.js — pick a port set for a new wp-env that collides with nothing.
 *
 * Usage:
 *   node find-free-ports.js [--repo <path>] [--root <path>]... [--depth <n>]
 *
 *   --repo   repository being set up (default: cwd). Its own .wp-env.json is not
 *            counted as "reserved", and explicit ports already in it are kept.
 *   --root   directory to scan for other repos' .wp-env.json (default: parent of --repo).
 *   --depth  how deep to look for .wp-env.json under each root (default: 3).
 *
 * stdout: one JSON object  {"port","testsPort","phpmyadminPort","testsPhpmyadminPort","kept":[...]}
 * stderr: the allocation table (who holds which port), for showing to the user.
 *
 * A port is unavailable when (a) another repo's .wp-env.json names it, (b) another repo
 * leaves port/testsPort unset and therefore uses the wp-env defaults 8888/8889, or
 * (c) something is listening on it right now.
 */
'use strict';

const fs = require( 'fs' );
const path = require( 'path' );
const { execSync } = require( 'child_process' );

const WEB_START = 8890; // 8888/8889 are wp-env's defaults: left to repos that never set a port.
const PMA_START = 9000;
const PORT_KEYS = [ 'port', 'testsPort', 'phpmyadminPort', 'mysqlPort' ];
const SKIP_DIRS = new Set( [ 'node_modules', 'vendor', '.git', 'tmp', 'build', 'dist' ] );

function parseArgs( argv ) {
	const args = { repo: process.cwd(), roots: [], depth: 3 };
	for ( let i = 0; i < argv.length; i++ ) {
		if ( argv[ i ] === '--repo' ) {
			args.repo = path.resolve( argv[ ++i ] );
		} else if ( argv[ i ] === '--root' ) {
			args.roots.push( path.resolve( argv[ ++i ] ) );
		} else if ( argv[ i ] === '--depth' ) {
			args.depth = parseInt( argv[ ++i ], 10 );
		} else {
			console.error( `Unknown argument: ${ argv[ i ] }` );
			process.exit( 2 );
		}
	}
	if ( ! args.roots.length ) {
		args.roots.push( path.dirname( args.repo ) );
	}
	return args;
}

function findConfigs( dir, depth, out ) {
	let entries;
	try {
		entries = fs.readdirSync( dir, { withFileTypes: true } );
	} catch ( e ) {
		return;
	}
	for ( const entry of entries ) {
		const full = path.join( dir, entry.name );
		if ( entry.isFile() && entry.name === '.wp-env.json' ) {
			out.push( full );
		} else if ( entry.isDirectory() && depth > 0 && ! SKIP_DIRS.has( entry.name ) ) {
			findConfigs( full, depth - 1, out );
		}
	}
}

// Returns [{ port, key, env }] for every port a config names, plus which defaults it relies on.
function readConfig( file ) {
	const text = fs.readFileSync( file, 'utf8' );
	const found = [];
	let usesDefaultPort = true;
	let usesDefaultTestsPort = true;
	let json = null;
	try {
		json = JSON.parse( text );
	} catch ( e ) {
		// Invalid JSON: wp-env could not start from it either, but its author still meant
		// to claim these ports, so fall back to a textual scan rather than ignore the file.
		const re = /"(port|testsPort|phpmyadminPort|mysqlPort)"\s*:\s*(\d+)/g;
		let m;
		while ( ( m = re.exec( text ) ) ) {
			found.push( { port: Number( m[ 2 ] ), key: m[ 1 ], env: '?' } );
			usesDefaultPort = usesDefaultPort && m[ 1 ] !== 'port';
			usesDefaultTestsPort = usesDefaultTestsPort && m[ 1 ] !== 'testsPort';
		}
		return { found, usesDefaultPort, usesDefaultTestsPort, invalid: true };
	}
	const scopes = [
		[ 'root', json ],
		[ 'development', json.env && json.env.development ],
		[ 'tests', json.env && json.env.tests ],
	];
	for ( const [ env, scope ] of scopes ) {
		if ( ! scope || typeof scope !== 'object' ) {
			continue;
		}
		for ( const key of PORT_KEYS ) {
			if ( Number.isInteger( scope[ key ] ) ) {
				found.push( { port: scope[ key ], key, env } );
			}
		}
		// env.development.port and env.tests.port are how a per-environment web port is set.
		if ( env !== 'tests' && Number.isInteger( scope.port ) ) {
			usesDefaultPort = false;
		}
		if ( Number.isInteger( scope.testsPort ) || ( env === 'tests' && Number.isInteger( scope.port ) ) ) {
			usesDefaultTestsPort = false;
		}
	}
	return { found, usesDefaultPort, usesDefaultTestsPort, invalid: false };
}

function listeningPorts() {
	const ports = new Set();
	const tryCmd = ( cmd, re ) => {
		try {
			const out = execSync( cmd, { encoding: 'utf8', stdio: [ 'ignore', 'pipe', 'ignore' ] } );
			let m;
			while ( ( m = re.exec( out ) ) ) {
				ports.add( Number( m[ 1 ] ) );
			}
			return true;
		} catch ( e ) {
			return false;
		}
	};
	// lsof exits 1 when nothing matches, which execSync reports as failure: "|| true" keeps
	// an empty result from being mistaken for "lsof is unavailable".
	const ok =
		tryCmd( 'lsof -nP -iTCP -sTCP:LISTEN || true', /:(\d+) \(LISTEN\)/g ) ||
		tryCmd( 'ss -ltnH', /:(\d+)\s/g );
	return { ports, ok };
}

function main() {
	const args = parseArgs( process.argv.slice( 2 ) );
	const selfConfig = path.join( args.repo, '.wp-env.json' );

	const configs = [];
	for ( const root of args.roots ) {
		findConfigs( root, args.depth, configs );
	}

	// port -> [owner descriptions]
	const reserved = new Map();
	const reserve = ( port, owner ) => {
		if ( ! reserved.has( port ) ) {
			reserved.set( port, [] );
		}
		reserved.get( port ).push( owner );
	};

	let defaultUsers = 0;
	const invalidFiles = [];
	for ( const file of configs ) {
		if ( path.resolve( file ) === path.resolve( selfConfig ) ) {
			continue;
		}
		const repoName = path.relative( args.roots[ 0 ], path.dirname( file ) ) || path.basename( path.dirname( file ) );
		const cfg = readConfig( file );
		if ( cfg.invalid ) {
			invalidFiles.push( file );
		}
		for ( const f of cfg.found ) {
			reserve( f.port, `${ repoName } (${ f.env === 'root' ? '' : f.env + '.' }${ f.key })` );
		}
		if ( cfg.usesDefaultPort ) {
			reserve( 8888, `${ repoName } (default port)` );
			defaultUsers++;
		}
		if ( cfg.usesDefaultTestsPort ) {
			reserve( 8889, `${ repoName } (default testsPort)` );
		}
	}

	const listening = listeningPorts();

	// Ports this repo already names are its own: keep them instead of reassigning, so a
	// re-run never moves an environment whose URL is already bookmarked or in test config.
	const kept = [];
	const own = { port: null, testsPort: null, phpmyadminPort: null, testsPhpmyadminPort: null };
	if ( fs.existsSync( selfConfig ) ) {
		try {
			const json = JSON.parse( fs.readFileSync( selfConfig, 'utf8' ) );
			const dev = ( json.env && json.env.development ) || {};
			const tests = ( json.env && json.env.tests ) || {};
			own.port = json.port ?? dev.port ?? null;
			own.testsPort = json.testsPort ?? tests.port ?? null;
			own.phpmyadminPort = dev.phpmyadminPort ?? json.phpmyadminPort ?? null;
			own.testsPhpmyadminPort = tests.phpmyadminPort ?? null;
		} catch ( e ) {
			console.error( `WARNING: ${ selfConfig } is not valid JSON; treating this repo as unconfigured.` );
		}
	}

	const taken = ( port ) => reserved.has( port ) || listening.ports.has( port );

	// 9001 alone is shared by 15+ repos on a typical machine: naming them all buries the answer.
	const summarize = ( owners ) =>
		owners.length > 3 ? `${ owners.slice( 0, 3 ).join( ', ' ) } … +${ owners.length - 3 } more` : owners.join( ', ' );

	// A pair (n, n+1) with n even keeps dev/tests adjacent: 8890/8891, 8892/8893, ...
	const firstFreePair = ( start ) => {
		for ( let n = start; n < start + 200; n += 2 ) {
			if ( ! taken( n ) && ! taken( n + 1 ) ) {
				return n;
			}
		}
		throw new Error( `No free port pair found from ${ start }` );
	};

	const result = {};
	const conflicts = [];
	const settle = ( name, ownValue, fallback ) => {
		if ( Number.isInteger( ownValue ) ) {
			result[ name ] = ownValue;
			kept.push( name );
			// Listening is expected when this repo's own environment is running, so only
			// another repo's claim on the same number counts as a conflict.
			if ( reserved.has( ownValue ) ) {
				conflicts.push( `${ name } ${ ownValue } is also claimed by: ${ summarize( reserved.get( ownValue ) ) }` );
			}
		} else {
			result[ name ] = fallback();
		}
	};

	let webPair = null;
	let pmaPair = null;
	const web = () => ( webPair === null ? ( webPair = firstFreePair( WEB_START ) ) : webPair );
	const pma = () => ( pmaPair === null ? ( pmaPair = firstFreePair( PMA_START ) ) : pmaPair );

	settle( 'port', own.port, () => web() );
	settle( 'testsPort', own.testsPort, () => web() + 1 );
	settle( 'phpmyadminPort', own.phpmyadminPort, () => pma() );
	settle( 'testsPhpmyadminPort', own.testsPhpmyadminPort, () => pma() + 1 );
	result.kept = kept;
	result.conflicts = conflicts;

	// ---- allocation table (stderr) ----
	// Listening ports nobody claims matter only inside the ranges this script assigns from.
	const strays = [ ...listening.ports ].filter( ( p ) => ! reserved.has( p ) && p >= 8880 && p <= 9099 );
	const rows = [ ...reserved.keys(), ...strays ].sort( ( a, b ) => a - b );
	console.error( `Scanned ${ configs.length } .wp-env.json under: ${ args.roots.join( ', ' ) }` );
	console.error( '' );
	console.error( 'PORT   HELD BY' );
	for ( const port of rows ) {
		const label = reserved.has( port ) ? summarize( reserved.get( port ) ) : '(no .wp-env.json claims it)';
		console.error( `${ String( port ).padEnd( 6 ) } ${ label }${ listening.ports.has( port ) ? '   [LISTENING NOW]' : '' }` );
	}
	console.error( '' );
	if ( defaultUsers > 0 ) {
		console.error( `${ defaultUsers } repo(s) rely on the wp-env defaults 8888/8889, so those are never assigned here.` );
	}
	if ( ! listening.ok ) {
		console.error( 'WARNING: neither lsof nor ss is available; ports in use right now were NOT checked.' );
	}
	for ( const file of invalidFiles ) {
		console.error( `WARNING: invalid JSON, ports read by text scan: ${ file }` );
	}
	for ( const c of conflicts ) {
		console.error( `CONFLICT: ${ c }` );
	}
	console.error( `→ assigned: ${ JSON.stringify( result ) }` );

	process.stdout.write( JSON.stringify( result ) + '\n' );
	process.exit( conflicts.length ? 3 : 0 );
}

main();
