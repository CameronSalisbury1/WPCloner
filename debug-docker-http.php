<?php
/**
 * Temporary debug plugin - logs outgoing HTTP requests
 * Check results via: docker logs wp-setup-wordpress-1 2>&1 | grep DEBUG
 */

error_log( '[DEBUG-HTTP] Plugin loaded on: ' . $_SERVER['REQUEST_URI'] ?? 'unknown' );

// Log ALL outgoing HTTP requests (not just host.docker.internal)
add_filter( 'http_request_args', function( $args, $url ) {
    error_log( '[DEBUG-HTTP] Outgoing request to: ' . $url );
    error_log( '[DEBUG-HTTP] sslverify: ' . ( isset( $args['sslverify'] ) ? var_export( $args['sslverify'], true ) : 'not set' ) );
    error_log( '[DEBUG-HTTP] method: ' . ( $args['method'] ?? 'not set' ) );
    error_log( '[DEBUG-HTTP] headers: ' . json_encode( $args['headers'] ?? [] ) );
    return $args;
}, 10, 2 );

// Log ALL responses
add_action( 'http_api_debug', function( $response, $context, $transport, $args, $url ) {
    error_log( '[DEBUG-HTTP] Response from: ' . $url );
    if ( is_wp_error( $response ) ) {
        error_log( '[DEBUG-HTTP] WP_Error: ' . $response->get_error_code() . ' - ' . $response->get_error_message() );
    } else {
        error_log( '[DEBUG-HTTP] Response code: ' . wp_remote_retrieve_response_code( $response ) );
        error_log( '[DEBUG-HTTP] Response body: ' . substr( wp_remote_retrieve_body( $response ), 0, 500 ) );
    }
}, 10, 5 );

// Log form submission to help correlate timing
add_action( 'gform_after_submission', function( $entry, $form ) {
    error_log( '[DEBUG-HTTP] gform_after_submission fired for form ID: ' . $form['id'] );
}, 10, 2 );
