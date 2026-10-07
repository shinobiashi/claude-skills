#!/usr/bin/env php
<?php
/**
 * Sign a webhook fixture the way an email provider would, for tests and local replays.
 *
 * Usage:
 *   sign-webhook.php --scheme svix --secret whsec_… --body fixture.json [--id msg_x] [--timestamp N] [--json] [--url URL]
 *   sign-webhook.php --scheme hmac --secret s3cret --header X-Signature --body fixture.json [--json] [--url URL]
 *   sign-webhook.php --scheme none --body fixture.json --url URL
 *
 * Prints curl -H lines (default) or a JSON object {headers:{…}} with --json.
 * With --url it POSTs the body with the headers and prints status + response.
 */
declare( strict_types=1 );

$opts = getopt( '', [ 'scheme:', 'secret:', 'body:', 'id:', 'timestamp:', 'header:', 'json', 'url:' ] );
$scheme = $opts['scheme'] ?? 'svix';
$body_path = $opts['body'] ?? null;
if ( null === $body_path || ! is_readable( $body_path ) ) {
    fwrite( STDERR, "--body <file> is required and must be readable\n" );
    exit( 2 );
}
$body = (string) file_get_contents( $body_path );
$headers = [ 'Content-Type' => 'application/json' ];

switch ( $scheme ) {
    case 'svix':
        $secret = $opts['secret'] ?? '';
        if ( 0 !== strpos( $secret, 'whsec_' ) ) {
            fwrite( STDERR, "--secret must start with whsec_\n" );
            exit( 2 );
        }
        $key = base64_decode( substr( $secret, 6 ), true );
        if ( false === $key ) {
            fwrite( STDERR, "secret is not valid base64\n" );
            exit( 2 );
        }
        $id = $opts['id'] ?? ( 'msg_' . bin2hex( random_bytes( 10 ) ) );
        $ts = (string) ( $opts['timestamp'] ?? time() );
        $sig = base64_encode( hash_hmac( 'sha256', $id . '.' . $ts . '.' . $body, $key, true ) );
        $headers += [ 'svix-id' => $id, 'svix-timestamp' => $ts, 'svix-signature' => 'v1,' . $sig ];
        break;
    case 'hmac':
        $secret = $opts['secret'] ?? '';
        $name = $opts['header'] ?? 'X-Signature';
        if ( '' === $secret ) {
            fwrite( STDERR, "--secret is required for --scheme hmac\n" );
            exit( 2 );
        }
        $headers[ $name ] = hash_hmac( 'sha256', $body, $secret );
        break;
    case 'none':
        break;
    default:
        fwrite( STDERR, "unknown --scheme {$scheme} (svix|hmac|none)\n" );
        exit( 2 );
}

if ( isset( $opts['url'] ) ) {
    $lines = [];
    foreach ( $headers as $k => $v ) {
        $lines[] = $k . ': ' . $v;
    }
    $ctx = stream_context_create( [ 'http' => [
        'method'        => 'POST',
        'header'        => implode( "\r\n", $lines ),
        'content'       => $body,
        'ignore_errors' => true,
        'timeout'       => 15,
    ] ] );
    $response = file_get_contents( $opts['url'], false, $ctx );
    $status = $http_response_header[0] ?? 'no response';
    echo $status, "\n", (string) $response, "\n";
    exit( 0 );
}

if ( isset( $opts['json'] ) ) {
    echo json_encode( [ 'headers' => $headers ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ), "\n";
    exit( 0 );
}
foreach ( $headers as $k => $v ) {
    echo '-H ', escapeshellarg( $k . ': ' . $v ), " \\\n";
}
