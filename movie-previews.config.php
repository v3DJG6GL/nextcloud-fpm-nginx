<?php
/**
 * Enable video thumbnail/preview generation (MP4, MKV, MOV, AVI, WebM, …).
 *
 * Bind-mount this into the config dir (see compose.yaml / README):
 *   - ./movie-previews.config.php:/var/www/html/config/zz-movie-previews.config.php:ro
 *
 * Two things are required for video previews; this file covers one of them:
 *   1. ffmpeg must exist in the image  — added in the Dockerfile (the base
 *      nextcloud:*-fpm image ships none, which is why videos show only a
 *      generic icon while images/PDFs/text get thumbnails).
 *   2. OC\Preview\Movie must be enabled — done here. It is DISABLED by default
 *      in every Nextcloud version for performance/privacy reasons.
 *
 * IMPORTANT: setting enabledPreviewProviders REPLACES Nextcloud's entire
 * default provider set (it does not merge), so the full default list is
 * re-listed below alongside Movie. Drop an entry only if you truly don't want
 * that preview type. The single OC\Preview\Movie provider (MIME regex
 * /video\/.*​/) covers ALL video formats — there is no separate MP4/MKV/AVI
 * provider class.
 *
 * After first enabling this, existing videos stay icon-only until backfilled:
 *   docker exec -u www-data <ctr> php occ preview:generate-all -vvv
 * (requires the "previewgenerator" app installed from the App Store).
 */
$CONFIG = [
    'enable_previews' => true,
    'enabledPreviewProviders' => [
        // ── Nextcloud defaults (re-listed because the key replaces, not merges) ──
        'OC\Preview\PNG',
        'OC\Preview\JPEG',
        'OC\Preview\GIF',
        'OC\Preview\BMP',
        'OC\Preview\XBitmap',
        'OC\Preview\Krita',
        'OC\Preview\WebP',
        'OC\Preview\MarkDown',
        'OC\Preview\TXT',
        'OC\Preview\OpenDocument',
        // ── Video (needs ffmpeg in the image) ──
        'OC\Preview\Movie',
    ],

    // Only needed if ffmpeg is NOT on PATH. With the Dockerfile apt install it
    // lives at /usr/bin/ffmpeg (on PATH), so this stays commented.
    // 'preview_ffmpeg_path' => '/usr/bin/ffmpeg',
];
