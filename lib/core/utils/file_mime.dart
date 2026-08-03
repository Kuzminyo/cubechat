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
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'csv' => 'text/csv',
    'zip' => 'application/zip',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'm4a' => 'audio/mp4',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    _ => declared ?? 'application/octet-stream',
  };
}
