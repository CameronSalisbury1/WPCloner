<?php
/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the installation.
 * You don't have to use the website, you can copy this file to "wp-config.php"
 * and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * Database settings
 * * Secret keys
 * * Database table prefix
 * * ABSPATH
 *
 * @link https://developer.wordpress.org/advanced-administration/wordpress/wp-config/
 *
 * @package WordPress
 */

/** Log environment vars for verification */
$wpHome = getenv('WP_HOME') ?: 'https://mywordpress-app.azurewebsites.net';
$wpSiteUrl = getenv('WP_SITEURL') ?: 'https://mywordpress-app.azurewebsites.net/';
$adminEmail = getenv('ADMIN_EMAIL') ?: 'admin@mywordpress-app.azurewebsites.net';
error_log("WP_HOME: $wpHome");
error_log("WP_SITEURL: $wpSiteUrl");
error_log("ADMIN_EMAIL: $adminEmail");

/** Define WordPress settings */
define('WP_HOME', $wpHome);
define('WP_SITEURL', $wpSiteUrl);
define('ADMIN_EMAIL', $adminEmail);

define( 'upload_max_filesize' , '40G');
@ini_set( 'upload_max_filesize' , getenv('UPLOAD_MAX_FILESIZE') );

@ini_set( 'post_max_size', getenv('POST_MAX_SIZE'));
//@ini_set( 'memory_limit', getenv('memory_limit') );
@ini_set( 'max_execution_time', getenv('MAX_EXECUTION_TIME') );
@ini_set( 'max_input_time', getenv('MAX_INPUT_TIME') );


// ** Database settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define('DB_NAME', getenv('DB_NAME') ?: '' );

/** Database username */
define('DB_USER', getenv('DB_USER') ?: '' );

/** Database password */
define('DB_PASSWORD', getenv('DB_PASSWORD') ?: '' );

/** Database hostname */
define('DB_HOST', getenv('DB_HOST') ?: '' );

/** Database charset to use in creating database tables. */
define( 'DB_CHARSET', 'utf8' );

/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', '' );

/** The Azure stroage account integration. */


/** Define SSL connection to Azure MySQL */
define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);
define('MYSQL_SSL_CA', './certs/azure_mysql_ca_bundle.pem');

/**#@+
 * Authentication unique keys and salts.
 *
 * Change these to different unique phrases! You can generate these using
 * the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}.
 *
 * You can change these at any point in time to invalidate all existing cookies.
 * This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
define( 'AUTH_KEY',         getenv('AUTH_KEY') ?: '' );
define( 'SECURE_AUTH_KEY',  getenv('SECURE_AUTH_KEY') ?: '' );
define( 'LOGGED_IN_KEY',    getenv('LOGGED_IN_KEY') ?: '' );
define( 'NONCE_KEY',        getenv('NONCE_KEY') ?: '' );
define( 'AUTH_SALT',        getenv('AUTH_SALT') ?: '' );
define( 'SECURE_AUTH_SALT', getenv('SECURE_AUTH_SALT') ?: '' );
define( 'LOGGED_IN_SALT',   getenv('LOGGED_IN_SALT') ?: '' );
define( 'NONCE_SALT',       getenv('NONCE_SALT') ?: '' );

/**#@-*/

/**
 * WordPress database table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 *
 * At the installation time, database tables are created with the specified prefix.
 * Changing this value after WordPress is installed will make your site think
 * it has not been installed.
 *
 * @link https://developer.wordpress.org/advanced-administration/wordpress/wp-config/#table-prefix
 */
$table_prefix = 'wp_';

/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the documentation.
 *
 * @link https://developer.wordpress.org/advanced-administration/debug/debug-wordpress/
 */
define( 'WP_DEBUG', false );
define( 'WP_DEBUG_LOG', false);

/* Add any custom values between this line and the "stop editing" line. */

if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
}

/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
        define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';

/*add_filter( 'gravityflow_webhook_args', function(  $args, $entry, $current_step ) {
    $secret = 'wt-webhook-secret-2024-hmac-signing';    
    $body = isset( $args['body'] ) ? (string) $args['body'] : '';         
    $signature = hash_hmac( 'sha256', $body, $secret );
    $args['headers']['X-Hub-Signature-256'] = 'sha256=' . $signature;
    $args['headers']['X-atanga'] = 'haumaru';
    return $args;
}, 10, 4 );*/

add_filter( 'gravityflow_webhook_args', function( $args, $entry, $current_step ) {
    $secret = 'wt-webhook-secret-2024-hmac-signing';

    // Get the body - check what format it's in
    $body = isset( $args['body'] ) ? $args['body'] : '';

    // Convert to string if it's an array (this might be the issue!)
    if ( is_array( $body ) ) {
        error_log( '[GF HMAC DEBUG] Body is an ARRAY - converting to query string' );
        error_log( '[GF HMAC DEBUG] Array keys: ' . implode( ', ', array_keys( $body ) ) );
        $body = http_build_query( $body );
    } else {
        error_log( '[GF HMAC DEBUG] Body is already a STRING' );
    }

    // Log body details for debugging
    error_log( '[GF HMAC DEBUG] Body length: ' . strlen( $body ) );
    error_log( '[GF HMAC DEBUG] Body first 200 chars: ' . substr( $body, 0, 200 ) );
    error_log( '[GF HMAC DEBUG] Body last 50 chars: ' . substr( $body, -50 ) );

    // Compute HMAC
    $signature = hash_hmac( 'sha256', $body, $secret );

    // Log the computed signature
    error_log( '[GF HMAC DEBUG] Computed signature: ' . $signature );
    error_log( '[GF HMAC DEBUG] Full header value: sha256=' . $signature );

    // Set headers
    $args['headers']['X-Hub-Signature-256'] = 'sha256=' . $signature;
    $args['headers']['X-atanga'] = 'haumaru';

    // Important: Ensure the body that gets sent is the SAME as what we computed HMAC on
    $args['body'] = $body;

    // Log what we're about to send
    error_log( '[GF HMAC DEBUG] Final args body type: ' . gettype( $args['body'] ) );
    error_log( '[GF HMAC DEBUG] Final args body length: ' . strlen( $args['body'] ) );

    return $args;
}, 10, 4 );

define('FS_METHOD', 'direct');

add_filter('gravityflow_notification', 'change_gravityflow_notification_email', 10, 4);
function change_gravityflow_notification_email($notification, $form, $entry, $step) {
    error_log('GravityFlow notification email changed to betty@enlighten.co.nz for form ID ' . $form['id']);
    $notification['to'] = 'betty@enlighten.co.nz';
    return $notification;
}

add_filter( 'gravityflow_workflow_url', 'sh_custom_workflow_url', 10, 3 );
function sh_custom_workflow_url( $url, $page_id, $assignee ) {
    error_log('Original Url: ' . $url);
    
    $parsed_url = parse_url($original_url);
    $new_domain = 'func-nzn-wt-uat-grantsapi.azurewebsites.net';

    if ($parsed_url) {
        $new_url = 'https://' . $new_domain;
        if (!empty($parsed_url['path'])) {
            $new_url .= $parsed_url['path'];
        }
        if (!empty($parsed_url['query'])) {
            $new_url .= '?' . $parsed_url['query'];
        }
        
        error_log(' New Url: ' . $new_url);
        
        return $new_url;
    }
    
    return $url;
}