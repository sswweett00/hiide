import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

/// A parsed block of markdown. `type` is one of h1–h4, p, code, ul, quote, hr.
class MdBlock {
  final String type;
  final String text;
  final List<String> items;

  const MdBlock({required this.type, this.text = '', this.items = const []});
}

/// Splits [content] into simple markdown blocks: headings, paragraphs, fenced
/// code, bullet lists, blockquotes and horizontal rules. Pure function so the
/// parser is trivially unit-testable.
List<MdBlock> parseMarkdown(String content) {
  final blocks = <MdBlock>[];
  final lines = content.split('\n');
  final codeBuffer = <String>[];
  var inCode = false;

  void flushCode() {
    if (codeBuffer.isNotEmpty) {
      blocks.add(MdBlock(type: 'code', text: codeBuffer.join('\n')));
      codeBuffer.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      if (inCode) {
        flushCode();
        inCode = false;
      } else {
        flushCode();
        inCode = true;
      }
      i++;
      continue;
    }
    if (inCode) {
      codeBuffer.add(line);
      i++;
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      flushCode();
      blocks.add(MdBlock(
          type: 'h${heading.group(1)!.length}', text: heading.group(2)!));
      i++;
      continue;
    }

    if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      flushCode();
      blocks.add(const MdBlock(type: 'hr'));
      i++;
      continue;
    }

    if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
      flushCode();
      final items = <String>[];
      while (i < lines.length && RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i])) {
        items.add(lines[i].replaceFirst(RegExp(r'^\s*[-*+]\s+'), ''));
        i++;
      }
      blocks.add(MdBlock(type: 'ul', items: items));
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushCode();
      final quoteLines = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quoteLines.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      blocks.add(MdBlock(type: 'quote', text: quoteLines.join('\n')));
      continue;
    }

    if (trimmed.isEmpty) {
      flushCode();
      i++;
      continue;
    }

    flushCode();
    final para = <String>[];
    while (i < lines.length) {
      final l = lines[i];
      if (l.trim().isEmpty) break;
      if (l.trim().startsWith('```')) break;
      if (RegExp(r'^(#{1,6})\s').hasMatch(l)) break;
      para.add(l);
      i++;
    }
    blocks.add(MdBlock(type: 'p', text: para.join('\n')));
  }
  flushCode();
  return blocks;
}

/// Inline markdown (bold, inline code, links) → rich text spans.
List<InlineSpan> markdownInlineSpans(
  String text,
  TextStyle base, {
  required Color codeColor,
  required Color linkColor,
}) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\))');
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    }
    final token = m.group(0)!;
    if (token.startsWith('`')) {
      spans.add(TextSpan(
        text: token.substring(1, token.length - 1),
        style: base.copyWith(
          fontFamily: 'JetBrains Mono',
          fontSize: base.fontSize! - 1,
          color: codeColor,
          backgroundColor: codeColor.withValues(alpha: 0.12),
        ),
      ));
    } else if (token.startsWith('**')) {
      spans.add(TextSpan(
        text: token.substring(2, token.length - 2),
        style: base.copyWith(fontWeight: FontWeight.bold),
      ));
    } else {
      final inner = token.substring(1, token.length - 1);
      final close = inner.lastIndexOf('](');
      final label = inner.substring(0, close);
      spans.add(TextSpan(
        text: label,
        style: base.copyWith(
            color: linkColor, decoration: TextDecoration.underline),
      ));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: base));
  }
  return spans;
}

/// Renders markdown [content] with a minimal, dependency-free renderer: used
/// for the README / .md split preview in the editor.
class MarkdownPreview extends StatelessWidget {
  final String content;

  const MarkdownPreview({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final blocks = parseMarkdown(content);

    return Container(
      color: cs.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(DesignTokens.space5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final block in blocks) _block(block, cs),
          ],
        ),
      ),
    );
  }

  Widget _block(MdBlock block, ColorScheme cs) {
    final base = TextStyle(
        color: cs.onSurface, fontSize: DesignTokens.fontSizeMD, height: 1.6);
    final codeColor = DesignTokens.aiCyan;
    final linkColor = cs.primary;

    switch (block.type) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
        final level = int.tryParse(block.type.substring(1)) ?? 2;
        final size = switch (level) {
          1 => 26.0,
          2 => 22.0,
          3 => 18.0,
          _ => 16.0,
        };
        return Padding(
          padding: const EdgeInsets.only(
              top: DesignTokens.space4, bottom: DesignTokens.space2),
          child: Text.rich(
            TextSpan(
              style: base.copyWith(
                fontSize: size,
                fontWeight: FontWeight.bold,
                color: level <= 2 ? cs.primary : cs.onSurface,
              ),
              children: markdownInlineSpans(block.text, base,
                  codeColor: codeColor, linkColor: linkColor),
            ),
          ),
        );
      case 'code':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
          padding: const EdgeInsets.all(DesignTokens.space3),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: SelectableText(
            block.text,
            style: base.copyWith(
              fontFamily: 'JetBrains Mono',
              fontSize: DesignTokens.fontSizeSM,
              color: cs.onSurface,
            ),
          ),
        );
      case 'ul':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in block.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: DesignTokens.space1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('•  ',
                          style: base.copyWith(
                              color: cs.primary, fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                              children: markdownInlineSpans(item, base,
                                  codeColor: codeColor, linkColor: linkColor)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case 'quote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
          padding: const EdgeInsets.only(
              left: DesignTokens.space3,
              top: DesignTokens.space1,
              bottom: DesignTokens.space1),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: cs.primary, width: 3)),
          ),
          child: Text.rich(
            TextSpan(
                children: markdownInlineSpans(
                    block.text,
                    base.copyWith(
                        fontStyle: FontStyle.italic,
                        color: cs.onSurfaceVariant),
                    codeColor: codeColor,
                    linkColor: linkColor)),
          ),
        );
      case 'hr':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: DesignTokens.space3),
          child: Divider(color: cs.outlineVariant),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: DesignTokens.space2),
          child: Text.rich(
            TextSpan(
                children: markdownInlineSpans(block.text, base,
                    codeColor: codeColor, linkColor: linkColor)),
          ),
        );
    }
  }
}
