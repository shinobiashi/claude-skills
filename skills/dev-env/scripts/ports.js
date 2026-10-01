#!/usr/bin/env node
/*
 * ports.js — the wp-env port ledger: one 10-port slot per repository, clear of WordPress Studio.
 *
 * Usage:
 *   node ports.js list                  print every slot in the ledger with its ports
 *   node ports.js get [<repo>]          print the repo's ports as JSON (exit 4 when not registered)
 *   node ports.js assign [<repo>]       register <repo> in the lowest free slot (no-op when registered)
 *   node ports.js check [--strict]      compare every repo's wp-env config, Studio's sites and the
 *                                       ports listening right now against the ledger
 *   node ports.js ps [--all]            name the repository behind each running wp-env instance (the
 *                                       hash or wp-env-<repo>-<hash> that Docker Desktop groups its
 *                                       containers by); --all adds instances on disk that are stopped
 *
 * Options:
 *   --root <dir>     where repositories live (repeatable; default ~/Dev). A repo's ledger key is
 *                    its path relative to the first root that contains it.
 *   --depth <n>      how deep `check` looks for .wp-env.json under each root (default 3)
 *   --ledger <file>  ledger to use. Default: $DEV_ENV_LEDGER, else the claude-skills source
 *                    checkout ($CLAUDE_SKILLS_REPO or ~/Dev/claude-skills)/skills/dev-env/ports.json,
 *                    else the copy next to this script.
 *   --studio <file>  Studio's site list (default ~/.studio/cli.json, then the older appdata-v1.json)
 *
 * Environment: WP_ENV_HOME (wp-env's instance directory, default ~/.wp-env). Test seams:
 * DEV_ENV_DOCKER names a substitute docker command, DEV_ENV_LSOF_OUTPUT a file of lsof output.
 *
 * <repo> is a directory (default: cwd) or a ledger key such as "cart-bridge-jp".
 *
 * Slot NN owns ports 10000 + NN*10 + 0..9:
 *   +0 development WordPress, +1 tests WordPress, +2 development phpMyAdmin, +3 tests phpMyAdmin,
 *   +4..+9 spare. Slot 08 is never assigned (10080 is on the browsers' unsafe-port list).
 *
 * Exit codes: 0 ok, 1 check found errors (or warnings with --strict), 2 usage error,
 *             3 the ledger is invalid, read-only or full, 4 repo not registered (get).
 */
'use strict';

const fs = require( 'fs' );
const os = require( 'os' );
const path = require( 'path' );
const crypto = require( 'crypto' );
const { execSync, execFileSync } = require( 'child_process' );

const BASE = 10000;
const SLOT_SIZE = 10;
const MAX_SLOT = 99;
const BAND = [ BASE + SLOT_SIZE, BASE + MAX_SLOT * SLOT_SIZE + SLOT_SIZE - 1 ]; // 10010..10999
const BLOCKED_SLOTS = new Map( [ [ 8, '10080 is on the browsers\' unsafe-port list' ] ] );
const STUDIO_BAND = [ 8881, 8999 ];
const STUDIO_FIRST_PORT = 8881;
const AVOID = new Map( [
	[ 3000, 'common Node dev servers' ],
	[ 5000, 'macOS AirPlay Receiver' ],
	[ 5173, 'Vite dev server' ],
	[ 7000, 'macOS AirPlay Receiver' ],
	[ 8080, 'common HTTP dev servers' ],
	[ 9003, 'Xdebug: the IDE listens here' ],
] );
const SKIP_DIRS = new Set( [ 'node_modules', 'vendor', '.git', 'tmp', 'build', 'dist' ] );
// Docker Desktop listens as com.docker.backend, which plain lsof truncates to "com.docke" (9 chars):
// match the stem so either spelling counts as a container.
const CONTAINER_LISTENER = /docke|vpnkit|orbstack|colima|lima|podman|rancher|qemu/i;

// ---------------------------------------------------------------------------- arguments

function parseArgs( argv ) {
	const args = { command: null, target: null, roots: [], depth: 3, ledger: null, studio: null, strict: false, all: false };
	for ( let i = 0; i < argv.length; i++ ) {
		const a = argv[ i ];
		const value = () => {
			if ( i + 1 >= argv.length ) {
				usage( `${ a } needs a value` );
			}
			return argv[ ++i ];
		};
		if ( a === '--root' ) {
			args.roots.push( path.resolve( expandHome( value() ) ) );
		} else if ( a === '--depth' ) {
			args.depth = parseInt( value(), 10 );
		} else if ( a === '--ledger' ) {
			args.ledger = path.resolve( expandHome( value() ) );
		} else if ( a === '--studio' ) {
			args.studio = path.resolve( expandHome( value() ) );
		} else if ( a === '--strict' ) {
			args.strict = true;
		} else if ( a === '--all' ) {
			args.all = true;
		} else if ( a === '-h' || a === '--help' ) {
			printHelp();
			process.exit( 0 );
		} else if ( a.startsWith( '--' ) ) {
			usage( `Unknown option: ${ a }` );
		} else if ( args.command === null ) {
			args.command = a;
		} else if ( args.target === null ) {
			args.target = a;
		} else {
			usage( `Unexpected argument: ${ a }` );
		}
	}
	if ( ! [ 'list', 'get', 'assign', 'check', 'ps' ].includes( args.command ) ) {
		usage( args.command === null ? 'Missing command' : `Unknown command: ${ args.command }` );
	}
	if ( ! Number.isInteger( args.depth ) || args.depth < 0 ) {
		usage( '--depth must be a non-negative integer' );
	}
	if ( ! args.roots.length ) {
		args.roots.push( path.join( os.homedir(), 'Dev' ) );
	}
	return args;
}

function expandHome( p ) {
	return p === '~' || p.startsWith( '~/' ) ? path.join( os.homedir(), p.slice( 1 ) ) : p;
}

function printHelp() {
	const text = fs.readFileSync( __filename, 'utf8' );
	const header = text.slice( text.indexOf( '/*' ) + 2, text.indexOf( '*/' ) );
	process.stdout.write( header.replace( /^ \* ?/gm, '' ).trim() + '\n' );
}

function usage( message ) {
	console.error( `ports.js: ${ message } (see --help)` );
	process.exit( 2 );
}

function fail( code, message ) {
	console.error( `ports.js: ${ message }` );
	process.exit( code );
}

// ---------------------------------------------------------------------------- ledger

function ledgerPath( args ) {
	if ( args.ledger ) {
		return args.ledger;
	}
	if ( process.env.DEV_ENV_LEDGER ) {
		return path.resolve( expandHome( process.env.DEV_ENV_LEDGER ) );
	}
	const repo = process.env.CLAUDE_SKILLS_REPO
		? path.resolve( expandHome( process.env.CLAUDE_SKILLS_REPO ) )
		: path.join( os.homedir(), 'Dev', 'claude-skills' );
	const source = path.join( repo, 'skills', 'dev-env', 'ports.json' );
	return fs.existsSync( source ) ? source : path.join( __dirname, '..', 'ports.json' );
}

// The installed copy is overwritten by install.sh (rsync --delete): a slot written there is lost.
function installedSkillsDir() {
	return path.resolve( expandHome( process.env.CLAUDE_SKILLS_DIR || path.join( os.homedir(), '.claude', 'skills' ) ) );
}

function isInstalledCopy( file ) {
	return path.resolve( file ).startsWith( installedSkillsDir() + path.sep );
}

function loadLedger( file ) {
	let ledger;
	try {
		ledger = JSON.parse( fs.readFileSync( file, 'utf8' ) );
	} catch ( e ) {
		fail( 3, `cannot read the ledger ${ file }: ${ e.message }` );
	}
	if ( ! ledger || typeof ledger !== 'object' || ! Array.isArray( ledger.repos ) ) {
		fail( 3, `${ file }: expected an object with a "repos" array` );
	}
	const problems = [];
	const slots = new Map();
	const repos = new Map();
	ledger.repos.forEach( ( entry, i ) => {
		const where = `repos[${ i }]`;
		if ( ! entry || typeof entry !== 'object' ) {
			problems.push( `${ where } is not an object` );
			return;
		}
		const { slot, repo } = entry;
		if ( ! Number.isInteger( slot ) || slot < 1 || slot > MAX_SLOT ) {
			problems.push( `${ where }: slot must be an integer 1-${ MAX_SLOT } (got ${ JSON.stringify( slot ) })` );
		} else if ( BLOCKED_SLOTS.has( slot ) ) {
			problems.push( `${ where }: slot ${ pad( slot ) } is never assigned (${ BLOCKED_SLOTS.get( slot ) })` );
		} else if ( slots.has( slot ) ) {
			problems.push( `${ where }: slot ${ pad( slot ) } is already held by ${ slots.get( slot ) }` );
		}
		if ( typeof repo !== 'string' || repo === '' || path.isAbsolute( repo ) || repo.split( '/' ).includes( '..' ) ) {
			problems.push( `${ where }: repo must be a path relative to the root (got ${ JSON.stringify( repo ) })` );
		} else if ( repos.has( repo ) ) {
			problems.push( `${ where }: ${ repo } is already registered in slot ${ pad( repos.get( repo ) ) }` );
		}
		if ( Number.isInteger( slot ) && typeof repo === 'string' ) {
			slots.set( slot, repo );
			repos.set( repo, slot );
		}
	} );
	if ( problems.length ) {
		fail( 3, `${ file } is invalid:\n  ${ problems.join( '\n  ' ) }` );
	}
	return { ledger, bySlot: slots, byRepo: repos };
}

// One entry per line keeps a new registration a one-line diff.
function formatLedger( ledger ) {
	const lines = [ '{' ];
	for ( const key of Object.keys( ledger ).filter( ( k ) => k !== 'repos' ) ) {
		lines.push( `\t${ JSON.stringify( key ) }: ${ JSON.stringify( ledger[ key ] ) },` );
	}
	lines.push( '\t"repos": [' );
	const sorted = [ ...ledger.repos ].sort( ( a, b ) => a.slot - b.slot );
	sorted.forEach( ( entry, i ) => {
		const body = Object.entries( entry )
			.map( ( [ k, v ] ) => `${ JSON.stringify( k ) }: ${ JSON.stringify( v ) }` )
			.join( ', ' );
		lines.push( `\t\t{ ${ body } }${ i < sorted.length - 1 ? ',' : '' }` );
	} );
	lines.push( '\t]', '}' );
	return lines.join( '\n' ) + '\n';
}

function slotPorts( slot ) {
	const start = BASE + slot * SLOT_SIZE;
	return { slot, port: start, testsPort: start + 1, phpmyadminPort: start + 2, testsPhpmyadminPort: start + 3 };
}

function slotOf( port ) {
	return port >= BAND[ 0 ] && port <= BAND[ 1 ] ? Math.floor( ( port - BASE ) / SLOT_SIZE ) : null;
}

function pad( slot ) {
	return String( slot ).padStart( 2, '0' );
}

// ---------------------------------------------------------------------------- repositories

// A directory argument becomes "path relative to its root"; anything else is taken as a key.
// Both sides go through realpath: process.cwd() is already resolved (macOS /var -> /private/var).
function repoKey( target, roots ) {
	let candidate = path.resolve( expandHome( target ?? '.' ) );
	let isDir = false;
	try {
		isDir = fs.statSync( candidate ).isDirectory();
		candidate = fs.realpathSync( candidate );
	} catch ( e ) {
		isDir = false;
	}
	if ( ! isDir ) {
		if ( target === null ) {
			usage( 'the current directory is not readable' );
		}
		return target.replace( /\/+$/, '' );
	}
	for ( const root of roots ) {
		let real = root;
		try {
			real = fs.realpathSync( root );
		} catch ( e ) {
			continue;
		}
		const rel = path.relative( real, candidate );
		if ( rel && ! rel.startsWith( '..' ) && ! path.isAbsolute( rel ) ) {
			return rel.split( path.sep ).join( '/' );
		}
	}
	usage( `${ candidate } is not under ${ roots.join( ', ' ) }; pass --root <dir> or the ledger key` );
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
			out.push( dir );
		} else if ( entry.isDirectory() && depth > 0 && ! SKIP_DIRS.has( entry.name ) ) {
			findConfigs( full, depth - 1, out );
		}
	}
}

function deepMerge( base, override ) {
	if ( ! isPlainObject( base ) || ! isPlainObject( override ) ) {
		return override;
	}
	const out = { ...base };
	for ( const [ k, v ] of Object.entries( override ) ) {
		out[ k ] = k in base ? deepMerge( base[ k ], v ) : v;
	}
	return out;
}

function isPlainObject( v ) {
	return v !== null && typeof v === 'object' && ! Array.isArray( v );
}

// The ports wp-env will actually bind, following its own precedence: .wp-env.override.json is
// merged over .wp-env.json, env.<name>.* beats the root, the root port/testsPort belong to
// development/tests only, and every other root option (phpmyadminPort, mysqlPort) is inherited
// by both environments. WP_ENV_PORT and friends are invisible here, which is why they are banned.
function effectivePorts( dir ) {
	const files = [ '.wp-env.json', '.wp-env.override.json' ];
	let merged = {};
	const sources = [];
	for ( const name of files ) {
		const file = path.join( dir, name );
		if ( ! fs.existsSync( file ) ) {
			continue;
		}
		let json;
		try {
			json = JSON.parse( fs.readFileSync( file, 'utf8' ) );
		} catch ( e ) {
			return { invalid: `${ name } is not valid JSON (${ e.message })` };
		}
		if ( ! isPlainObject( json ) ) {
			return { invalid: `${ name } is not a JSON object` };
		}
		merged = deepMerge( merged, json );
		sources.push( name );
	}
	const envOf = ( name ) => ( isPlainObject( merged.env ) && isPlainObject( merged.env[ name ] ) ? merged.env[ name ] : {} );
	const int = ( v ) => ( Number.isInteger( v ) ? v : undefined );
	const dev = envOf( 'development' );
	const tests = envOf( 'tests' );
	return {
		sources,
		ports: {
			port: int( dev.port ) ?? int( merged.port ) ?? 8888,
			testsPort: int( tests.port ) ?? int( merged.testsPort ) ?? 8889,
			phpmyadminPort: int( dev.phpmyadminPort ) ?? int( merged.phpmyadminPort ) ?? null,
			testsPhpmyadminPort: int( tests.phpmyadminPort ) ?? int( merged.phpmyadminPort ) ?? null,
			mysqlPort: int( dev.mysqlPort ) ?? int( merged.mysqlPort ) ?? null,
			testsMysqlPort: int( tests.mysqlPort ) ?? int( merged.mysqlPort ) ?? null,
		},
		defaults: {
			port: int( dev.port ) === undefined && int( merged.port ) === undefined,
			testsPort: int( tests.port ) === undefined && int( merged.testsPort ) === undefined,
		},
	};
}

function scanRepos( roots, depth ) {
	const repos = new Map(); // key -> { dir, ...effectivePorts }
	for ( const root of roots ) {
		const dirs = [];
		findConfigs( root, depth, dirs );
		for ( const dir of dirs ) {
			const key = path.relative( root, dir ).split( path.sep ).join( '/' );
			if ( key && ! repos.has( key ) ) {
				repos.set( key, { dir, ...effectivePorts( dir ) } );
			}
		}
	}
	return repos;
}

// ---------------------------------------------------------------------------- machine state

function studioSites( override ) {
	const candidates = override
		? [ override ]
		: [
				path.join( os.homedir(), '.studio', 'cli.json' ),
				path.join( os.homedir(), 'Library', 'Application Support', 'Studio', 'appdata-v1.json' ),
		  ];
	for ( const file of candidates ) {
		if ( ! fs.existsSync( file ) ) {
			continue;
		}
		try {
			const json = JSON.parse( fs.readFileSync( file, 'utf8' ) );
			const sites = ( Array.isArray( json.sites ) ? json.sites : [] )
				.filter( ( s ) => s && Number.isInteger( s.port ) )
				.map( ( s ) => ( { port: s.port, name: typeof s.name === 'string' ? s.name : '(unnamed)' } ) );
			return { file, sites };
		} catch ( e ) {
			return { file, sites: [], error: e.message };
		}
	}
	return null;
}

// port -> Set of process names. `ok` is false when neither lsof nor ss could be run.
function listeners() {
	const map = new Map();
	const add = ( port, name ) => {
		if ( ! map.has( port ) ) {
			map.set( port, new Set() );
		}
		map.get( port ).add( name );
	};
	const run = ( cmd ) => {
		try {
			return execSync( cmd, { encoding: 'utf8', stdio: [ 'ignore', 'pipe', 'ignore' ] } );
		} catch ( e ) {
			return null;
		}
	};
	// lsof exits 1 when nothing matches: "|| true" keeps an empty result from reading as "no lsof".
	// "+c 0" prints whole command names instead of the first 9 characters. DEV_ENV_LSOF_OUTPUT
	// (a file of lsof output) stands in for the real command in tests.
	const fake = process.env.DEV_ENV_LSOF_OUTPUT;
	const lsof = fake
		? fs.readFileSync( fake, 'utf8' )
		: run( 'command -v lsof >/dev/null && { lsof +c 0 -nP -iTCP -sTCP:LISTEN || true; }' );
	if ( lsof !== null && lsof !== '' ) {
		for ( const line of lsof.split( '\n' ).slice( 1 ) ) {
			const m = line.match( /^(\S+)\s.*:(\d+) \(LISTEN\)\s*$/ );
			if ( m ) {
				add( Number( m[ 2 ] ), m[ 1 ].replace( /\\x20/g, ' ' ) );
			}
		}
		return { map, ok: true };
	}
	const ss = run( 'ss -ltnpH' );
	if ( ss !== null ) {
		for ( const line of ss.split( '\n' ) ) {
			const m = line.match( /:(\d+)\s+\S+:\S+\s*(?:users:\(\("([^"]+)")?/ );
			if ( m ) {
				add( Number( m[ 1 ] ), m[ 2 ] || '?' );
			}
		}
		return { map, ok: true };
	}
	return { map, ok: lsof === '' };
}

// wp-env keeps each environment in <WP_ENV_HOME or ~/.wp-env>/<name>, and Docker Compose takes the
// project name (the group Docker Desktop shows) from that directory. The name is md5 of the config
// file's path (the legacy form, kept for as long as that directory exists) or, for environments that
// @wordpress/env 11.x creates, wp-env-<directory name>-<the first 8 hex digits of that md5>.
function wpEnvHome() {
	return path.resolve( expandHome( process.env.WP_ENV_HOME || path.join( os.homedir(), '.wp-env' ) ) );
}

function instanceNamesFor( dir ) {
	const dirs = [ dir ];
	try {
		const real = fs.realpathSync( dir );
		if ( real !== dir ) {
			dirs.push( real );
		}
	} catch ( e ) {
		// The scan found this directory a moment ago; the plain path is enough.
	}
	const names = new Set();
	for ( const d of dirs ) {
		const hash = crypto.createHash( 'md5' ).update( path.join( d, '.wp-env.json' ) ).digest( 'hex' );
		names.add( hash );
		names.add( `wp-env-${ path.basename( d ) }-${ hash.slice( 0, 8 ) }` );
	}
	return names;
}

function docker( dockerArgs ) {
	try {
		return execFileSync( process.env.DEV_ENV_DOCKER || 'docker', dockerArgs, {
			encoding: 'utf8',
			stdio: [ 'ignore', 'pipe', 'ignore' ],
		} );
	} catch ( e ) {
		return null;
	}
}

function publishedWebPort( ports ) {
	const m = ( ports || '' ).match( /:(\d+)->80\/tcp/ );
	return m ? Number( m[ 1 ] ) : null;
}

// ---------------------------------------------------------------------------- commands

function cmdList( args ) {
	const file = ledgerPath( args );
	const { ledger } = loadLedger( file );
	console.log( `Ledger: ${ file }` );
	console.log( '' );
	console.log( 'SLOT  WEB dev/tests  PMA dev/tests  REPO' );
	for ( const entry of [ ...ledger.repos ].sort( ( a, b ) => a.slot - b.slot ) ) {
		const p = slotPorts( entry.slot );
		const note = entry.note ? `  (${ entry.note })` : '';
		console.log( `${ pad( entry.slot ).padEnd( 5 ) } ${ `${ p.port }/${ p.testsPort }`.padEnd( 14 ) } ${ `${ p.phpmyadminPort }/${ p.testsPhpmyadminPort }`.padEnd( 14 ) } ${ entry.repo }${ note }` );
	}
}

function cmdGet( args ) {
	const key = repoKey( args.target, args.roots );
	const { byRepo } = loadLedger( ledgerPath( args ) );
	if ( ! byRepo.has( key ) ) {
		fail( 4, `${ key } is not in the ledger; register it with: node ${ path.relative( process.cwd(), __filename ) } assign ${ key }` );
	}
	process.stdout.write( JSON.stringify( { repo: key, ...slotPorts( byRepo.get( key ) ) } ) + '\n' );
}

function cmdAssign( args ) {
	const key = repoKey( args.target, args.roots );
	const file = ledgerPath( args );
	const { ledger, bySlot, byRepo } = loadLedger( file );
	if ( byRepo.has( key ) ) {
		console.error( `${ key } is already registered in slot ${ pad( byRepo.get( key ) ) }.` );
		process.stdout.write( JSON.stringify( { repo: key, ...slotPorts( byRepo.get( key ) ) } ) + '\n' );
		return;
	}
	if ( isInstalledCopy( file ) ) {
		fail(
			3,
			`refusing to write ${ file }: it is the installed copy, which install.sh overwrites.\n` +
				'  Clone the source (git clone https://github.com/shinobiashi/claude-skills.git ~/Dev/claude-skills)\n' +
				'  or point --ledger / DEV_ENV_LEDGER at its skills/dev-env/ports.json.'
		);
	}

	// A slot is free only if nothing already sits on any of its ten ports: an unregistered repo's
	// config, a Studio site, or a live listener (a running instance nobody registered).
	const busy = new Map(); // port -> reason
	for ( const [ other, info ] of scanRepos( args.roots, args.depth ) ) {
		if ( other !== key && info.ports ) {
			for ( const port of Object.values( info.ports ) ) {
				if ( Number.isInteger( port ) ) {
					busy.set( port, `${ other }'s wp-env config` );
				}
			}
		}
	}
	const studio = studioSites( args.studio );
	for ( const site of studio ? studio.sites : [] ) {
		busy.set( site.port, `Studio site "${ site.name }"` );
	}
	for ( const [ port, names ] of listeners().map ) {
		busy.set( port, `listening now (${ [ ...names ].join( ', ' ) })` );
	}

	const skipped = [];
	let chosen = null;
	for ( let slot = 1; slot <= MAX_SLOT && chosen === null; slot++ ) {
		if ( bySlot.has( slot ) || BLOCKED_SLOTS.has( slot ) ) {
			continue;
		}
		const start = BASE + slot * SLOT_SIZE;
		const clash = [ ...Array( SLOT_SIZE ).keys() ].map( ( i ) => start + i ).find( ( p ) => busy.has( p ) );
		if ( clash !== undefined ) {
			skipped.push( `slot ${ pad( slot ) }: ${ clash } is used by ${ busy.get( clash ) }` );
			continue;
		}
		chosen = slot;
	}
	if ( chosen === null ) {
		fail( 3, `no free slot left in ${ file }` );
	}

	ledger.repos.push( { slot: chosen, repo: key } );
	fs.writeFileSync( file, formatLedger( ledger ) );
	for ( const s of skipped ) {
		console.error( `skipped ${ s }` );
	}
	console.error( `Registered ${ key } in slot ${ pad( chosen ) } of ${ file } (not committed).` );
	process.stdout.write( JSON.stringify( { repo: key, ...slotPorts( chosen ) } ) + '\n' );
}

function cmdCheck( args ) {
	const file = ledgerPath( args );
	const { bySlot, byRepo } = loadLedger( file );
	const repos = scanRepos( args.roots, args.depth );
	const studio = studioSites( args.studio );
	const listening = listeners();
	const studioPorts = new Map( ( studio ? studio.sites : [] ).map( ( s ) => [ s.port, s.name ] ) );

	// Which repos name each port, to tell a duplicated slot from a merely pending one.
	const owners = new Map();
	for ( const [ key, info ] of repos ) {
		for ( const port of info.ports ? new Set( Object.values( info.ports ) ) : [] ) {
			if ( Number.isInteger( port ) ) {
				owners.set( port, [ ...( owners.get( port ) || [] ), key ] );
			}
		}
	}

	const rows = [];
	const errors = [];
	const warnings = [];
	const fmt = ( p ) => `${ p.port }/${ p.testsPort }${ p.phpmyadminPort ? ` pma ${ p.phpmyadminPort }/${ p.testsPhpmyadminPort ?? '-' }` : '' }`;

	for ( const [ key, info ] of [ ...repos ].sort( ( a, b ) => ( byRepo.get( a[ 0 ] ) ?? 1000 ) - ( byRepo.get( b[ 0 ] ) ?? 1000 ) || a[ 0 ].localeCompare( b[ 0 ] ) ) ) {
		const slot = byRepo.get( key );
		const slotLabel = slot ? pad( slot ) : '--';
		if ( info.invalid ) {
			rows.push( [ slotLabel, key, 'ERROR', info.invalid ] );
			errors.push( `${ key }: ${ info.invalid }` );
			continue;
		}
		const p = info.ports;
		const named = [ p.port, p.testsPort, p.phpmyadminPort, p.testsPhpmyadminPort, p.mysqlPort, p.testsMysqlPort ];
		const notes = [];
		let status;

		// Two containers of the same repo on one host port: wp-env itself fails to start.
		const pairs = [
			[ 'phpmyadminPort', p.phpmyadminPort, 'testsPhpmyadminPort', p.testsPhpmyadminPort ],
			[ 'mysqlPort', p.mysqlPort, 'testsMysqlPort', p.testsMysqlPort ],
		];
		const selfClash = pairs.filter( ( [ , a, , b ] ) => a !== null && a === b ).map( ( [ n, a ] ) => `${ n } ${ a } is shared by development and tests` );
		const webPorts = [ p.port, p.testsPort, p.phpmyadminPort, p.testsPhpmyadminPort ].filter( ( x ) => x !== null );
		if ( new Set( webPorts ).size !== webPorts.length && ! selfClash.length ) {
			selfClash.push( `the same port is used twice in ${ webPorts.join( '/' ) }` );
		}

		if ( ! slot ) {
			status = 'ERROR';
			notes.push( `not in the ledger: run "ports.js assign ${ key }"` );
		} else {
			const want = slotPorts( slot );
			const start = BASE + slot * SLOT_SIZE;
			const mysqlOk = ( m ) => m === null || ( m >= start + 4 && m <= start + 9 );
			const matches =
				p.port === want.port &&
				p.testsPort === want.testsPort &&
				( p.phpmyadminPort === null || p.phpmyadminPort === want.phpmyadminPort ) &&
				( p.testsPhpmyadminPort === null || p.testsPhpmyadminPort === want.testsPhpmyadminPort ) &&
				mysqlOk( p.mysqlPort ) &&
				mysqlOk( p.testsMysqlPort );
			const inBand = named.filter( ( x ) => x !== null && slotOf( x ) !== null );
			if ( matches ) {
				status = 'ok';
				for ( const port of new Set( named.filter( ( x ) => x !== null ) ) ) {
					const others = ( owners.get( port ) || [] ).filter( ( o ) => o !== key );
					if ( others.length ) {
						status = 'ERROR';
						notes.push( `${ port } is also used by ${ others.join( ', ' ) }` );
					}
				}
			} else if ( ! inBand.length ) {
				status = 'pending';
				notes.push( `migrate to ${ fmt( want ) }` );
			} else {
				status = 'ERROR';
				const foreign = [ ...new Set( inBand.map( slotOf ) ) ].filter( ( s ) => s !== slot );
				notes.push( `ports do not match slot ${ pad( slot ) } (${ fmt( want ) })` );
				for ( const s of foreign ) {
					notes.push( `slot ${ pad( s ) } belongs to ${ bySlot.get( s ) || '(unassigned)' }${ bySlot.get( s ) ? ' — copied from a template?' : '' }` );
				}
			}
		}
		if ( selfClash.length ) {
			status = 'ERROR';
			notes.push( ...selfClash );
		}
		if ( status !== 'ok' ) {
			const inStudio = [];
			for ( const port of new Set( named.filter( ( x ) => x !== null ) ) ) {
				if ( port >= STUDIO_BAND[ 0 ] && port <= STUDIO_BAND[ 1 ] ) {
					inStudio.push( studioPorts.has( port ) ? `${ port } "${ studioPorts.get( port ) }"` : String( port ) );
				} else if ( AVOID.has( port ) ) {
					notes.push( `${ port } is reserved (${ AVOID.get( port ) })` );
				}
			}
			if ( inStudio.length ) {
				notes.push( `in the Studio band: ${ inStudio.join( ', ' ) }` );
			}
		}
		const tags = [
			info.defaults.port || info.defaults.testsPort ? 'default' : null,
			info.sources.includes( '.wp-env.override.json' ) ? 'override' : null,
		].filter( Boolean );
		rows.push( [ slotLabel, key, status, `${ fmt( p ) }${ tags.length ? ` (${ tags.join( ', ' ) })` : '' }`, notes.join( '; ' ) ] );
		if ( status === 'ERROR' ) {
			errors.push( `${ key }: ${ notes.join( '; ' ) }` );
		}
	}

	const missing = [ ...byRepo.keys() ].filter( ( k ) => ! repos.has( k ) );
	for ( const key of missing ) {
		rows.push( [ pad( byRepo.get( key ) ), key, 'missing', '-', `no .wp-env.json under ${ args.roots.join( ', ' ) }` ] );
	}

	// Machine state: Studio must stay in its band, and nothing but containers may hold a slot.
	if ( studio ) {
		for ( const site of studio.sites ) {
			if ( slotOf( site.port ) !== null ) {
				errors.push( `Studio site "${ site.name }" uses ${ site.port }, inside the wp-env band (STUDIO_BASE_PORT moved?)` );
			}
		}
		const used = new Set( studio.sites.map( ( s ) => s.port ) );
		let next = STUDIO_FIRST_PORT;
		while ( used.has( next ) ) {
			next++;
		}
		if ( next > STUDIO_BAND[ 1 ] - 10 ) {
			warnings.push( `Studio's next site would take ${ next }: the Studio band ${ STUDIO_BAND.join( '-' ) } is almost full` );
		}
	}
	for ( const [ slot, key ] of bySlot ) {
		const start = BASE + slot * SLOT_SIZE;
		for ( let port = start; port < start + SLOT_SIZE; port++ ) {
			const names = [ ...( listening.map.get( port ) || [] ) ].filter( ( n ) => ! CONTAINER_LISTENER.test( n ) );
			if ( names.length ) {
				warnings.push( `${ port } (slot ${ pad( slot ) }, ${ key }) is held by ${ names.join( ', ' ) }, not a container` );
			}
		}
	}
	if ( ! listening.ok ) {
		warnings.push( 'neither lsof nor ss is available: listening ports were NOT checked' );
	}

	// ---- report
	const width = Math.max( 4, ...rows.map( ( r ) => r[ 1 ].length ) );
	console.log( `Ledger: ${ file }` );
	console.log( `Scanned ${ repos.size } .wp-env.json under ${ args.roots.join( ', ' ) }` );
	console.log( '' );
	console.log( `SLOT  ${ 'REPO'.padEnd( width ) }  STATUS   PORTS (dev/tests)` );
	for ( const [ slot, key, status, ports, notes ] of rows ) {
		console.log( `${ slot.padEnd( 4 ) }  ${ key.padEnd( width ) }  ${ status.padEnd( 7 ) }  ${ ports }${ notes ? `  — ${ notes }` : '' }` );
	}
	console.log( '' );
	if ( studio ) {
		const ports = studio.sites.map( ( s ) => s.port ).sort( ( a, b ) => a - b );
		const range = ports.length ? `${ ports[ 0 ] }-${ ports[ ports.length - 1 ] }` : 'none';
		console.log( `Studio: ${ ports.length } site(s), ports ${ range } (${ studio.file })${ studio.error ? ` — unreadable: ${ studio.error }` : '' }` );
	} else {
		console.log( 'Studio: not found' );
	}
	const count = ( s ) => rows.filter( ( r ) => r[ 2 ] === s ).length;
	console.log( `Summary: ok ${ count( 'ok' ) }, pending ${ count( 'pending' ) }, error ${ count( 'ERROR' ) }, missing ${ count( 'missing' ) }` );
	for ( const w of warnings ) {
		console.log( `WARN: ${ w }` );
	}
	for ( const e of errors ) {
		console.log( `ERROR: ${ e }` );
	}
	process.exit( errors.length || ( args.strict && ( warnings.length || count( 'pending' ) ) ) ? 1 : 0 );
}

function cmdPs( args ) {
	const { byRepo } = loadLedger( ledgerPath( args ) );
	const repos = scanRepos( args.roots, args.depth );
	const home = wpEnvHome();
	const byName = new Map();
	for ( const [ key, info ] of repos ) {
		for ( const name of instanceNamesFor( info.dir ) ) {
			byName.set( name, key );
		}
	}

	// Running containers, grouped by the wp-env instance (compose project) they belong to.
	const format = [
		'{{.Names}}',
		'{{.Label "com.docker.compose.project"}}',
		'{{.Label "com.docker.compose.project.working_dir"}}',
		'{{.Label "com.docker.compose.service"}}',
		'{{.Ports}}',
	].join( '\t' );
	const listing = docker( [ 'ps', '--format', format ] );
	const instances = new Map();
	for ( const line of ( listing || '' ).split( '\n' ) ) {
		const [ container, project, workdir, service, ports ] = line.split( '\t' );
		if ( ! container || ! service ) {
			continue;
		}
		const inHome = workdir && path.resolve( workdir ).startsWith( home + path.sep );
		if ( ! inHome && ! /^([0-9a-f]{32}|wp-env-.+)$/.test( project || '' ) ) {
			continue; // some other compose project
		}
		const name = inHome ? path.basename( workdir ) : project;
		if ( ! instances.has( name ) ) {
			instances.set( name, { name, running: true, services: new Map() } );
		}
		instances.get( name ).services.set( service, { container, port: publishedWebPort( ports ) } );
	}
	if ( args.all ) {
		let entries = [];
		try {
			entries = fs.readdirSync( home, { withFileTypes: true } );
		} catch ( e ) {
			entries = [];
		}
		for ( const entry of entries ) {
			if ( entry.isDirectory() && ! instances.has( entry.name ) ) {
				instances.set( entry.name, { name: entry.name, running: false, services: new Map() } );
			}
		}
	}

	// A config file under another name (a variant, a moved checkout) breaks the hash match; the
	// WordPress container's bind mounts still point at the repository.
	const byMount = ( inst ) => {
		const svc = inst.services.get( 'wordpress' ) || [ ...inst.services.values() ][ 0 ];
		const mounts = svc ? docker( [ 'inspect', '--format', '{{range .Mounts}}{{.Source}}{{"\\n"}}{{end}}', svc.container ] ) : null;
		const sources = ( mounts || '' ).split( '\n' ).map( ( m ) => m.replace( /^\/host_mnt(?=\/)/, '' ) ).filter( Boolean );
		let best = null;
		for ( const [ key, info ] of repos ) {
			const dir = info.dir;
			if ( sources.some( ( src ) => src === dir || src.startsWith( dir + path.sep ) ) && ( ! best || dir.length > repos.get( best ).dir.length ) ) {
				best = key;
			}
		}
		return best;
	};

	const rows = [];
	for ( const inst of instances.values() ) {
		let key = byName.get( inst.name ) || null;
		const notes = [];
		if ( ! key && inst.running ) {
			key = byMount( inst );
			if ( key ) {
				notes.push( 'matched by its mounts' );
			}
		}
		const slot = key ? byRepo.get( key ) : undefined;
		const port = ( service ) => ( inst.services.get( service ) || {} ).port ?? null;
		const dev = port( 'wordpress' );
		const tests = port( 'tests-wordpress' );
		const pma = [ port( 'phpmyadmin' ), port( 'tests-phpmyadmin' ) ];
		if ( ! key ) {
			notes.push( inst.running ? `no repository under ${ args.roots.join( ', ' ) }` : 'no repository found (left over from a moved or deleted checkout?)' );
		} else if ( ! slot ) {
			notes.push( 'not in the ledger' );
		} else if ( inst.running ) {
			const want = slotPorts( slot );
			if ( dev !== want.port || ( tests !== null && tests !== want.testsPort ) ) {
				notes.push( `not on slot ${ pad( slot ) } (${ want.port }/${ want.testsPort })` );
			}
		}
		rows.push( {
			name: inst.name,
			repo: key || '?',
			slot: slot ? pad( slot ) : '--',
			state: inst.running ? 'running' : 'stopped',
			web: inst.running ? `${ dev ?? '-' }/${ tests ?? '-' }` : '-',
			pma: pma.some( ( p ) => p !== null ) ? pma.map( ( p ) => p ?? '-' ).join( '/' ) : '-',
			note: notes.join( '; ' ),
			order: [ inst.running ? 0 : 1, slot ?? 1000 ],
		} );
	}
	rows.sort( ( a, b ) => a.order[ 0 ] - b.order[ 0 ] || a.order[ 1 ] - b.order[ 1 ] || a.name.localeCompare( b.name ) );

	if ( listing === null ) {
		console.log( 'WARN: docker is not reachable — running instances are not shown' + ( args.all ? '' : ' (add --all for the ones on disk)' ) );
	}
	if ( ! rows.length ) {
		console.log( args.all ? `No wp-env instances in ${ home }.` : 'No wp-env instance is running.' );
		return;
	}
	const w = ( field, title ) => Math.max( title.length, ...rows.map( ( r ) => r[ field ].length ) );
	const cols = [ [ 'name', 'INSTANCE' ], [ 'repo', 'REPO' ], [ 'slot', 'SLOT' ], [ 'state', 'STATE' ], [ 'web', 'WEB dev/tests' ], [ 'pma', 'PMA dev/tests' ] ];
	const widths = cols.map( ( [ f, t ] ) => w( f, t ) );
	console.log( cols.map( ( [ , t ], i ) => t.padEnd( widths[ i ] ) ).join( '  ' ) + '  NOTE' );
	for ( const r of rows ) {
		console.log( ( cols.map( ( [ f ], i ) => r[ f ].padEnd( widths[ i ] ) ).join( '  ' ) + ( r.note ? `  ${ r.note }` : '' ) ).trimEnd() );
	}
	console.log( '' );
	console.log( `Docker Desktop groups each instance's containers under its INSTANCE name (${ home }/<INSTANCE>).` );
}

// ---------------------------------------------------------------------------- main

const args = parseArgs( process.argv.slice( 2 ) );
( { list: cmdList, get: cmdGet, assign: cmdAssign, check: cmdCheck, ps: cmdPs } )[ args.command ]( args );
