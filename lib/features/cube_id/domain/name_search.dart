import 'cube_name.dart';

/// Whether a person matches what was typed into a search: by the name they
/// are saved under, or by the @name they were found by.
///
/// "@dima" found nobody — the search compared it with display names only, and
/// no display name starts with "@". The leading "@" is how people write a
/// Cube ID, so it is dropped before comparing, and a bare "dima" finds the
/// same person through either name.
bool matchesPeerSearch({
  required String query,
  required String peerName,
  String? cubeName,
}) {
  var q = query.trim().toLowerCase();
  if (q.startsWith('@')) q = q.substring(1);
  if (q.isEmpty) return true;
  return peerName.toLowerCase().contains(q) ||
      (cubeName != null && cubeName.toLowerCase().contains(q));
}

/// The @name a search could look up on Cube ID, or null.
///
/// Only for a query written as a Cube ID — with the "@" — so typing a friend's
/// first name never offers to ask the server about it. Null when the name is
/// not a valid one, is this phone's own, or already belongs to a contact: then
/// the list above already shows them.
String? cubeNameToLookUp(
  String query, {
  required Iterable<String> knownNames,
  String? ownName,
}) {
  final trimmed = query.trim();
  if (!trimmed.startsWith('@')) return null;
  final name = normalizeCubeName(trimmed);
  if (cubeNameProblem(name) == CubeNameProblem.invalid) return null;
  if (name == ownName) return null;
  if (knownNames.any((n) => n.toLowerCase() == name)) return null;
  return name;
}
