import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';

import '../test_tools.dart';
import 'document_test_tools.dart';
import 'supereditor_inspector.dart';
import 'supereditor_robot.dart';

void main() {
  group("SuperEditor gestures", () {
    testWidgetsOnAllPlatforms("in an empty document places the caret when tapping in empty space", (tester) async {
      // TODO:
    });

    testWidgetsOnDesktop(
        "dragging a single component selection above a component selects to the beginning of the component",
        (tester) async {
      // For example, a user drags to select text in a paragraph. The user
      // is dragging the cursor up the center of the paragraph. When the cursor
      // moves above the paragraph, the selection extent should move to the
      // beginning of the paragraph, rather than get stuck in the middle of the
      // top line of text.

      await tester
          .createDocument()
          .fromMarkdown(
            '''
This is a paragraph of text that
spans multiple lines.''',
          )
          .forDesktop()
          .pump();

      final document = SuperEditorInspector.findDocument()!;
      final paragraphNode = document.nodes.first as ParagraphNode;

      await tester.dragSelectDocumentFromPositionByOffset(
        from: DocumentPosition(
          nodeId: paragraphNode.id,
          nodePosition: paragraphNode.endPosition,
        ),
        delta: const Offset(0, -300),
      );

      // Ensure that the entire paragraph is selected, after dragging
      // above it.
      expect(
        SuperEditorInspector.findDocumentSelection(),
        DocumentSelection(
          base: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.endPosition,
          ),
          extent: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.beginningPosition,
          ),
        ),
      );
    });

    testWidgetsOnDesktop("dragging a single component selection below a component selects to the end of the component",
        (tester) async {
      // For example, a user drags to select text in a paragraph. The user
      // is dragging the cursor down the center of the paragraph. When the cursor
      // moves below the paragraph, the selection extent should move to the
      // end of the paragraph, rather than get stuck in the middle of the
      // bottom line of text.

      await tester
          .createDocument()
          .fromMarkdown(
            '''
This is a paragraph of text that
spans multiple lines.''',
          )
          .forDesktop()
          .pump();

      final document = SuperEditorInspector.findDocument()!;
      final paragraphNode = document.nodes.first as ParagraphNode;

      await tester.dragSelectDocumentFromPositionByOffset(
        from: DocumentPosition(
          nodeId: paragraphNode.id,
          nodePosition: paragraphNode.beginningPosition,
        ),
        delta: const Offset(0, 300),
      );

      // Ensure that the entire paragraph is selected, after dragging
      // below it.
      expect(
        SuperEditorInspector.findDocumentSelection(),
        DocumentSelection(
          base: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.beginningPosition,
          ),
          extent: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.endPosition,
          ),
        ),
      );
    });

    testWidgetsOnDesktop(
        "dragging a multi-component selection above a component selects to the beginning of the top component",
        (tester) async {
      // For example, a user drags to select text in a paragraph. The user
      // is dragging the cursor up the center of the paragraph. When the cursor
      // moves above the paragraph, the selection extent should move to the
      // beginning of the paragraph, rather than get stuck in the middle of the
      // top line of text.

      await tester
          .createDocument()
          .fromMarkdown(
            '''
# This is a test
This is a paragraph of text that
spans multiple lines.''',
          )
          .forDesktop()
          .pump();

      final document = SuperEditorInspector.findDocument()!;
      final titleNode = document.nodes.first as ParagraphNode;
      final paragraphNode = document.nodes[1] as ParagraphNode;

      await tester.dragSelectDocumentFromPositionByOffset(
        from: DocumentPosition(
          nodeId: paragraphNode.id,
          nodePosition: paragraphNode.endPosition,
        ),
        delta: const Offset(0, -300),
      );

      // Ensure that the entire paragraph is selected, after dragging
      // above it.
      expect(
        SuperEditorInspector.findDocumentSelection(),
        DocumentSelection(
          base: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.endPosition,
          ),
          extent: DocumentPosition(
            nodeId: titleNode.id,
            nodePosition: titleNode.beginningPosition,
          ),
        ),
      );
    });

    testWidgetsOnDesktop(
        "dragging a multi-component selection below a component selects to the end of the bottom component",
        (tester) async {
      // For example, a user drags to select text in a paragraph. The user
      // is dragging the cursor up the center of the paragraph. When the cursor
      // moves above the paragraph, the selection extent should move to the
      // beginning of the paragraph, rather than get stuck in the middle of the
      // top line of text.

      await tester
          .createDocument()
          .fromMarkdown(
            '''
# This is a test
This is a paragraph of text that
spans multiple lines.''',
          )
          .forDesktop()
          .pump();

      final document = SuperEditorInspector.findDocument()!;
      final titleNode = document.nodes.first as ParagraphNode;
      final paragraphNode = document.nodes[1] as ParagraphNode;

      await tester.dragSelectDocumentFromPositionByOffset(
        from: DocumentPosition(
          nodeId: titleNode.id,
          nodePosition: titleNode.beginningPosition,
        ),
        delta: const Offset(0, 300),
      );

      // Ensure that the entire paragraph is selected, after dragging
      // above it.
      expect(
        SuperEditorInspector.findDocumentSelection(),
        DocumentSelection(
          base: DocumentPosition(
            nodeId: titleNode.id,
            nodePosition: titleNode.beginningPosition,
          ),
          extent: DocumentPosition(
            nodeId: paragraphNode.id,
            nodePosition: paragraphNode.endPosition,
          ),
        ),
      );
    });
  });
}
