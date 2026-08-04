/// Resolves the MIME type used when sending or opening a file attachment.
///
/// Android routes files by MIME type. The document picker often gives us no
/// useful type, so attachments used to be sent as `application/octet-stream`;
/// a `.jpg` could then open in a generic Google app instead of Photos/Gallery.
String fileMimeType(
  String fileName, {
  String? declaredMime,
}) {
  final declared = declaredMime?.split(';').first.trim().toLowerCase();
  if (declared != null &&
      declared.isNotEmpty &&
      declared != 'application/octet-stream' &&
      declared != 'binary/octet-stream') {
    return declared;
  }

  final dot = fileName.lastIndexOf('.');
  final extension = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' || 'jpe' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    'tif' || 'tiff' => 'image/tiff',
    'ico' => 'image/x-icon',
    'pdf' => 'application/pdf',
    // The office formats, which is where this list mattered most and where it
    // was silent: a .docx announced as octet-stream matches no handler at all,
    // so Android reported that nothing could open a file every phone can open.
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument'
        '.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument'
        '.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument'
        '.presentationml.presentation',
    'odt' => 'application/vnd.oasis.opendocument.text',
    'ods' => 'application/vnd.oasis.opendocument.spreadsheet',
    'odp' => 'application/vnd.oasis.opendocument.presentation',
    'rtf' => 'application/rtf',
    'epub' => 'application/epub+zip',
    'txt' || 'log' || 'ini' || 'cfg' || 'conf' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'html' || 'htm' => 'text/html',
    'xml' => 'text/xml',
    'json' => 'application/json',
    'ics' => 'text/calendar',
    'vcf' => 'text/vcard',
    'zip' => 'application/zip',
    'rar' => 'application/vnd.rar',
    '7z' => 'application/x-7z-compressed',
    'tar' => 'application/x-tar',
    'gz' || 'tgz' => 'application/gzip',
    'apk' => 'application/vnd.android.package-archive',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/opus',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'm4a' => 'audio/mp4',
    'mp4' || 'm4v' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'avi' => 'video/x-msvideo',
    '3gp' => 'video/3gpp',
    _ => declared ?? 'application/octet-stream',
  };
}

/// True when [mime] says nothing — the value that means "some bytes".
///
/// Worth its own name because it is the one answer callers must not pass on to
/// the system: asked to open `application/octet-stream`, Android looks for an
/// app that has declared it can handle *anything*, finds none, and reports that
/// the file cannot be opened. Handing it nothing instead lets it resolve the
/// extension itself, which is both more likely to work and never worse.
bool isUnknownMime(String? mime) =>
    mime == null ||
    mime.trim().isEmpty ||
    mime == 'application/octet-stream' ||
    mime == 'binary/octet-stream';
