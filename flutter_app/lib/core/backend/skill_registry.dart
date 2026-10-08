import 'dart:io';

class HiideSkill {
  const HiideSkill({
    required this.id,
    required this.title,
    required this.description,
    required this.keywords,
    required this.content,
  });

  final String id;
  final String title;
  final String description;
  final List<String> keywords;
  final String content;
}

class HiideSkillRegistry {
  const HiideSkillRegistry();

  Future<List<HiideSkill>> load(String workspaceRoot) async {
    final dir = Directory(_skillsPath(workspaceRoot));
    if (!await dir.exists()) return const [];

    final skills = <HiideSkill>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      try {
        final raw = await entity.readAsString();
        final parsed = _parse(entity.path, raw);
        if (parsed != null) skills.add(parsed);
      } catch (_) {}
    }

    skills.sort((a, b) => a.id.compareTo(b.id));
    return skills;
  }

  Future<String> contextFor(
    String workspaceRoot,
    String request, {
    int maxSkills = 3,
    int maxChars = 12000,
  }) async {
    final skills = await load(workspaceRoot);
    if (skills.isEmpty) return '';

    final query = request.toLowerCase();
    final ranked = skills.map((skill) {
      var score = 0;
      for (final keyword in skill.keywords) {
        if (keyword.isNotEmpty && query.contains(keyword.toLowerCase())) {
          score += 3;
        }
      }
      if (query.contains(skill.title.toLowerCase())) score += 2;
      if (query.contains(skill.id.toLowerCase())) score += 2;
      return (skill: skill, score: score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final selected = ranked
        .where((entry) => entry.score > 0)
        .take(maxSkills)
        .map((entry) => entry.skill)
        .toList();

    if (selected.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('--- Hiide Skills (reference instructions) ---');
    for (final skill in selected) {
      if (buffer.length >= maxChars) break;
      buffer.writeln('\n## ' + skill.title);
      buffer.writeln(skill.content);
    }
    buffer.writeln('\n--- End Hiide Skills ---');

    final result = buffer.toString();
    if (result.length <= maxChars) return result;
    return result.substring(0, maxChars) + '\n…[skills truncated]';
  }

  String _skillsPath(String root) {
    final normalized = root.endsWith(Platform.pathSeparator)
        ? root.substring(0, root.length - 1)
        : root;
    return normalized +
        Platform.pathSeparator +
        '.hiide' +
        Platform.pathSeparator +
        'skills';
  }

  HiideSkill? _parse(String path, String raw) {
    final name = _basename(path);
    var body = raw.trim();
    var title = name.replaceFirst(RegExp(r'\.md$'), '');
    var description = '';
    var keywords = <String>[];

    if (body.startsWith('---')) {
      final end = body.indexOf('\n---', 3);
      if (end >= 0) {
        final frontmatter = body.substring(3, end).trim();
        body = body.substring(end + 4).trim();
        for (final line in frontmatter.split('\n')) {
          final separator = line.indexOf(':');
          if (separator <= 0) continue;
          final key = line.substring(0, separator).trim();
          final value = line.substring(separator + 1).trim();
          switch (key) {
            case 'name':
              if (value.isNotEmpty) title = value;
            case 'description':
              description = value;
            case 'keywords':
              keywords = value
                  .split(',')
                  .map((item) => item.trim())
                  .where((item) => item.isNotEmpty)
                  .toList();
          }
        }
      }
    }

    if (body.isEmpty) return null;
    return HiideSkill(
      id: name.replaceFirst(RegExp(r'\.md$'), ''),
      title: title,
      description: description,
      keywords: keywords,
      content: body,
    );
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\\\', '/');
    return normalized.split('/').last;
  }
}
