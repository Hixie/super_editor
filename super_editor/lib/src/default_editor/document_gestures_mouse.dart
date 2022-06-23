import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/default_editor/selection_upstream_downstream.dart';
import 'package:super_editor/src/default_editor/text_tools.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';
import 'package:super_editor/src/infrastructure/scrolling_diagnostics/_scrolling_minimap.dart';

import 'document_gestures.dart';

/// Governs mouse gesture interaction with a document, such as scrolling
/// a document with a scroll wheel, tapping to place a caret, and
/// tap-and-dragging to create an expanded selection.
///
/// See also: super_editor's touch gesture support.

/// Document gesture interactor that's designed for mouse input, e.g.,
/// drag to select, and mouse wheel to scroll.
///
///  - alters document selection on single, double, and triple taps
///  - alters document selection on drag, also account for single,
///    double, or triple taps to drag
///  - sets the cursor style based on hovering over text and other
///    components
///  - automatically scrolls up or down when the user drags near
///    a boundary
class DocumentMouseInteractor extends StatefulWidget {
  const DocumentMouseInteractor({
    Key? key,
    this.focusNode,
    required this.editContext,
    this.scrollController,
    this.selectionExtentAutoScrollBoundary = AxisOffset.zero,
    this.dragAutoScrollBoundary = const AxisOffset.symmetric(100),
    this.showDebugPaint = false,
    this.scrollingMinimapId,
    required this.child,
  }) : super(key: key);

  final FocusNode? focusNode;

  /// Service locator for document editing dependencies.
  final EditContext editContext;

  /// Controls the vertical scrolling of the given [child].
  ///
  /// If no `scrollController` is provided, then one is created
  /// internally.
  final ScrollController? scrollController;

  /// The closest distance between the user's selection extent (caret)
  /// and the boundary of a document before the document auto-scrolls
  /// to make room for the caret.
  ///
  /// The default value is zero for the leading and trailing boundaries.
  /// This means that the top of the caret is permitted to touch the top
  /// of the scrolling region, but if the caret goes above the viewport
  /// boundary then the document scrolls up. If the caret goes below the
  /// bottom of the viewport boundary then the document scrolls down.
  ///
  /// A positive value for each boundary creates a buffer zone at each
  /// edge of the viewport. For example, a value of `100.0` would cause
  /// the document to auto-scroll whenever the caret sits within 100
  /// pixels of the edge of a document.
  ///
  /// A negative value allows the caret to move outside the viewport
  /// before auto-scrolling.
  ///
  /// See also:
  ///
  ///  * [dragAutoScrollBoundary], which defines how close the user's
  ///    drag gesture can get to the document boundary before auto-scrolling.
  final AxisOffset selectionExtentAutoScrollBoundary;

  /// The closest that the user's selection drag gesture can get to the
  /// document boundary before auto-scrolling.
  ///
  /// The default value is `100.0` pixels for both the leading and trailing
  /// edges.
  ///
  /// See also:
  ///
  ///  * [selectionExtentAutoScrollBoundary], which defines how close the
  ///    selection extent can get to the document boundary before
  ///    auto-scrolling. For example, when the user taps into some text, or
  ///    when the user presses up/down arrows to move the selection extent.
  final AxisOffset dragAutoScrollBoundary;

  /// Paints some extra visual ornamentation to help with
  /// debugging, when `true`.
  final bool showDebugPaint;

  /// ID that this widget's scrolling system registers with an ancestor
  /// [ScrollingMinimaps] to report scrolling diagnostics for debugging.
  final String? scrollingMinimapId;

  /// The document to display within this [DocumentMouseInteractor].
  final Widget child;

  @override
  State createState() => _DocumentMouseInteractorState();
}

class _DocumentMouseInteractorState extends State<DocumentMouseInteractor> with SingleTickerProviderStateMixin {
  final _maxDragSpeed = 20.0;

  final _documentWrapperKey = GlobalKey();

  late FocusNode _focusNode;

  late ScrollController _scrollController;
  ScrollPosition? _ancestorScrollPosition;

  Offset? _cursorGlobalOffset;

  // Tracks user drag gestures for selection purposes.
  SelectionType _selectionType = SelectionType.position;
  bool _hasAncestorScrollable = false;
  Offset? _dragStartGlobal;
  double? _dragStartScrollOffset;
  Offset? _dragEndGlobal;
  bool _expandSelectionDuringDrag = false;

  bool _scrollUpOnTick = false;
  bool _scrollDownOnTick = false;
  late Ticker _ticker;

  // Current mouse cursor style displayed on screen.
  final _cursorStyle = ValueNotifier<MouseCursor>(SystemMouseCursors.basic);

  ScrollableInstrumentation? _debugInstrumentation;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ticker = createTicker(_onTick);
    _scrollController =
        _scrollController = (widget.scrollController ?? ScrollController())..addListener(_updateDragSelection);

    widget.editContext.composer.addListener(_onSelectionChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // If we were given a scrollingMinimapId, it means our client wants us
    // to report our scrolling behavior for debugging. Register with an
    // ancestor ScrollingMinimaps.
    if (widget.scrollingMinimapId != null) {
      _debugInstrumentation = ScrollableInstrumentation()
        ..viewport.value = Scrollable.of(context)!.context
        ..scrollPosition.value = Scrollable.of(context)!.position;
      ScrollingMinimaps.of(context)?.put(widget.scrollingMinimapId!, _debugInstrumentation);
    }
  }

  @override
  void didUpdateWidget(DocumentMouseInteractor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editContext.composer != oldWidget.editContext.composer) {
      oldWidget.editContext.composer.removeListener(_onSelectionChange);
      widget.editContext.composer.addListener(_onSelectionChange);
    }
    if (widget.scrollController != oldWidget.scrollController) {
      _scrollController.removeListener(_updateDragSelection);
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = (widget.scrollController ?? ScrollController())..addListener(_updateDragSelection);
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode = widget.focusNode ?? FocusNode();
    }
  }

  @override
  void dispose() {
    // TODO: Flutter says the following de-registration is unsafe. Where are we
    //       supposed to de-register from an ancestor?
    //       I'm commenting this out until we can find the right approach.
    // if (widget.scrollingMinimapId == null) {
    //   ScrollingMinimaps.of(context)?.put(widget.scrollingMinimapId!, null);
    // }

    widget.editContext.composer.removeListener(_onSelectionChange);
    _ticker.dispose();
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  /// Returns the layout for the current document, which answers questions
  /// about the locations and sizes of visual components within the layout.
  DocumentLayout get _docLayout => widget.editContext.documentLayout;

  /// Returns the `ScrollPosition` that controls the scroll offset of
  /// this widget.
  ///
  /// If this widget has an ancestor `Scrollable`, then the returned
  /// `ScrollPosition` belongs to that ancestor `Scrollable`, and this
  /// widget doesn't include a `ScrollView`.
  ///
  /// If this widget doesn't have an ancestor `Scrollable`, then this
  /// widget includes a `ScrollView` and the `ScrollView`'s position
  /// is returned.
  ScrollPosition get _scrollPosition => _ancestorScrollPosition ?? _scrollController.position;

  /// Returns the `RenderBox` for the scrolling viewport.
  ///
  /// If this widget has an ancestor `Scrollable`, then the returned
  /// `RenderBox` belongs to that ancestor `Scrollable`.
  ///
  /// If this widget doesn't have an ancestor `Scrollable`, then this
  /// widget includes a `ScrollView` and this `State`'s render object
  /// is the viewport `RenderBox`.
  RenderBox get _viewport =>
      (Scrollable.of(context)?.context.findRenderObject() ?? context.findRenderObject()) as RenderBox;

  bool get _isShiftPressed =>
      (RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
          RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight) ||
          RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shift)) &&
      widget.editContext.composer.selection != null;

  void _onSelectionChange() {
    if (mounted) {
      // Use a post-frame callback to "ensure selection extent is visible"
      // so that any pending visual document changes can happen before
      // attempting to calculate the visual position of the selection extent.
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        editorGesturesLog.finer("Ensuring selection extent is visible because the doc selection changed");
        _ensureSelectionExtentIsVisible();
      });
    }
  }

  void _ensureSelectionExtentIsVisible() {
    editorGesturesLog.finer("Ensuring extent is visible: ${widget.editContext.composer.selection}");
    final selection = widget.editContext.composer.selection;
    if (selection == null) {
      return;
    }

    // The reason that a Rect is used instead of an Offset is
    // because things like Images and Horizontal Rules don't have
    // a clear selection offset. They are either entirely selected,
    // or not selected at all.
    final selectionExtentRectInDoc = _docLayout.getRectForPosition(
      selection.extent,
    );
    if (selectionExtentRectInDoc == null) {
      editorGesturesLog.warning(
          "Tried to ensure that position ${selection.extent} is visible on screen but no bounding box was returned for that position.");
      return;
    }

    // Viewport might be our box, or an ancestor box if we're inside someone
    // else's Scrollable.
    final viewportBox = _viewport;

    final docBox = _documentWrapperKey.currentContext!.findRenderObject() as RenderBox;

    final docOffsetInViewport = viewportBox.globalToLocal(
      docBox.localToGlobal(Offset.zero),
    );
    final selectionExtentRectInViewport = selectionExtentRectInDoc.translate(0, docOffsetInViewport.dy);

    final beyondTopExtent = min(selectionExtentRectInViewport.top, 0).abs();

    final beyondBottomExtent = max(selectionExtentRectInViewport.bottom - viewportBox.size.height, 0);

    editorGesturesLog.finest('Ensuring extent is visible.');
    editorGesturesLog.finest(' - viewport size: ${viewportBox.size}');
    editorGesturesLog.finest(' - scroll controller offset: ${_scrollPosition.pixels}');
    editorGesturesLog.finest(' - selection extent rect: $selectionExtentRectInDoc');
    editorGesturesLog.finest(' - beyond top: $beyondTopExtent');
    editorGesturesLog.finest(' - beyond bottom: $beyondBottomExtent');

    if (beyondTopExtent > 0) {
      final newScrollPosition = (_scrollPosition.pixels - beyondTopExtent).clamp(0.0, _scrollPosition.maxScrollExtent);

      _scrollPosition.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondBottomExtent > 0) {
      final newScrollPosition =
          (beyondBottomExtent + _scrollPosition.pixels).clamp(0.0, _scrollPosition.maxScrollExtent);

      _scrollPosition.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  void _onTapUp(TapUpDetails details) {
    editorGesturesLog.info("Tap up on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    _focusNode.requestFocus();

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }

      if (_isShiftPressed && widget.editContext.composer.selection != null) {
        // The user tapped while pressing shift and there's an existing
        // selection. Move the extent of the selection to where the user tapped.
        widget.editContext.composer.selection = widget.editContext.composer.selection!.copyWith(
          extent: docPosition,
        );
      } else {
        // Place the document selection at the location where the
        // user tapped.
        _selectionType = SelectionType.position;
        _selectPosition(docPosition);
      }
    } else {
      editorGesturesLog.fine("No document content at ${details.globalPosition}.");
      _clearSelection();
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    editorGesturesLog.info("Double tap down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }
    }

    _selectionType = SelectionType.word;
    _clearSelection();

    if (docPosition != null) {
      bool didSelectContent = _selectWordAt(
        docPosition: docPosition,
        docLayout: _docLayout,
      );

      if (!didSelectContent) {
        didSelectContent = _selectBlockAt(docPosition);
      }

      if (!didSelectContent) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  bool _selectBlockAt(DocumentPosition position) {
    if (position.nodePosition is! UpstreamDownstreamNodePosition) {
      return false;
    }

    widget.editContext.composer.selection = DocumentSelection(
      base: DocumentPosition(
        nodeId: position.nodeId,
        nodePosition: const UpstreamDownstreamNodePosition.upstream(),
      ),
      extent: DocumentPosition(
        nodeId: position.nodeId,
        nodePosition: const UpstreamDownstreamNodePosition.downstream(),
      ),
    );

    return true;
  }

  void _onDoubleTap() {
    editorGesturesLog.info("Double tap up on document");
    _selectionType = SelectionType.position;
  }

  void _onTripleTapDown(TapDownDetails details) {
    editorGesturesLog.info("Triple down down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }
    }

    _selectionType = SelectionType.paragraph;
    _clearSelection();

    if (docPosition != null) {
      final didSelectParagraph = _selectParagraphAt(
        docPosition: docPosition,
        docLayout: _docLayout,
      );
      if (!didSelectParagraph) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  void _onTripleTap() {
    editorGesturesLog.info("Triple tap up on document");
    _selectionType = SelectionType.position;
  }

  void _onPanStart(DragStartDetails details) {
    editorGesturesLog.info("Pan start on document, global offset: ${details.globalPosition}");

    _hasAncestorScrollable = Scrollable.of(context) != null;

    _dragStartGlobal = details.globalPosition;
    _cursorGlobalOffset = details.globalPosition;

    _debugInstrumentation?.startDragInContent.value = _getDocOffsetFromGlobalOffset(_dragStartGlobal!);

    // We need to record the scroll offset at the beginning of
    // a drag for the case that this interactor is embedded
    // within an ancestor Scrollable. We need to use this value
    // to calculate a scroll delta on every scroll frame to
    // account for the fact that this interactor is moving within
    // the ancestor scrollable, despite the fact that the user's
    // finger/mouse position hasn't changed.
    _dragStartScrollOffset = _scrollPosition.pixels;

    if (_isShiftPressed) {
      _expandSelectionDuringDrag = true;
    }

    if (!_isShiftPressed) {
      // Only clear the selection if the user isn't pressing shift. Shift is
      // used to expand the current selection, not replace it.
      editorGesturesLog.fine("Shift isn't pressed. Clearing any existing selection before panning.");
      _clearSelection();
    }

    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      editorGesturesLog.info("Pan update on document, global offset: ${details.globalPosition}");

      _dragEndGlobal = details.globalPosition;
      _cursorGlobalOffset = details.globalPosition;

      _debugInstrumentation?.startDragInContent.value = _getDocOffsetFromGlobalOffset(_dragEndGlobal!);

      _updateCursorStyle();
      _updateDragSelection();

      _scrollIfNearBoundary();
    });
  }

  void _onPanEnd(DragEndDetails details) {
    editorGesturesLog.info("Pan end on document");
    _onDragEnd();
  }

  void _onPanCancel() {
    editorGesturesLog.info("Pan cancel on document");
    _onDragEnd();
  }

  void _onDragEnd() {
    setState(() {
      _dragStartGlobal = null;
      _dragEndGlobal = null;
      _expandSelectionDuringDrag = false;
    });

    _stopScrollingUp();
    _stopScrollingDown();
  }

  void _onMouseMove(PointerEvent pointerEvent) {
    _cursorGlobalOffset = pointerEvent.position;
    _updateCursorStyle();
  }

  bool _selectWordAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getWordSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editContext.composer.selection = newSelection;
      return true;
    } else {
      return false;
    }
  }

  bool _selectParagraphAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getParagraphSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editContext.composer.selection = newSelection;
      return true;
    } else {
      return false;
    }
  }

  void _selectPosition(DocumentPosition position) {
    editorGesturesLog.fine("Setting document selection to $position");
    widget.editContext.composer.selection = DocumentSelection.collapsed(
      position: position,
    );
  }

  void _updateDragSelection() {
    if (_dragEndGlobal == null) {
      // User isn't dragging. No need to update drag selection.
      return;
    }

    // We have to re-calculate the drag end in the doc (instead of
    // caching the value during the pan update) because the position
    // in the document is impacted by auto-scrolling behavior.
    final scrollDeltaWhileDragging = _dragStartScrollOffset! - _scrollPosition.pixels;

    final dragStartInDoc = _getDocOffsetFromGlobalOffset(_dragStartGlobal!) + Offset(0, scrollDeltaWhileDragging);
    final dragEndInDoc = _getDocOffsetFromGlobalOffset(_dragEndGlobal!);
    editorGesturesLog.finest(
      '''
Updating drag selection:
 - drag start in doc: $dragStartInDoc
 - drag end in doc: $dragEndInDoc''',
    );

    _selectRegion(
      documentLayout: _docLayout,
      baseOffsetInDocument: dragStartInDoc,
      extentOffsetInDocument: dragEndInDoc,
      selectionType: _selectionType,
      expandSelection: _expandSelectionDuringDrag,
    );
  }

  void _selectRegion({
    required DocumentLayout documentLayout,
    required Offset baseOffsetInDocument,
    required Offset extentOffsetInDocument,
    required SelectionType selectionType,
    bool expandSelection = false,
  }) {
    editorGesturesLog.info("Selecting region with selection mode: $selectionType");
    DocumentSelection? selection = documentLayout.getDocumentSelectionInRegion(
      baseOffsetInDocument,
      extentOffsetInDocument,
    );
    DocumentPosition? basePosition = selection?.base;
    DocumentPosition? extentPosition = selection?.extent;
    editorGesturesLog.fine(" - base: $basePosition, extent: $extentPosition");

    if (basePosition == null || extentPosition == null) {
      widget.editContext.composer.selection = null;
      return;
    }

    if (selectionType == SelectionType.paragraph) {
      final baseParagraphSelection = getParagraphSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseParagraphSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      basePosition = baseOffsetInDocument.dy < extentOffsetInDocument.dy
          ? baseParagraphSelection.base
          : baseParagraphSelection.extent;

      final extentParagraphSelection = getParagraphSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentParagraphSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      extentPosition = baseOffsetInDocument.dy < extentOffsetInDocument.dy
          ? extentParagraphSelection.extent
          : extentParagraphSelection.base;
    } else if (selectionType == SelectionType.word) {
      final baseWordSelection = getWordSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseWordSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      basePosition = baseWordSelection.base;

      final extentWordSelection = getWordSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentWordSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      extentPosition = extentWordSelection.extent;
    }

    widget.editContext.composer.selection = (DocumentSelection(
      // If desired, expand the selection instead of replacing it.
      base: expandSelection ? widget.editContext.composer.selection?.base ?? basePosition : basePosition,
      extent: extentPosition,
    ));
    editorGesturesLog.fine("Selected region: ${widget.editContext.composer.selection}");
  }

  void _clearSelection() {
    editorGesturesLog.fine("Clearing document selection");
    widget.editContext.composer.clearSelection();
  }

  void _updateCursorStyle() {
    final cursorOffsetInDocument = _getDocOffsetFromGlobalOffset(_cursorGlobalOffset!);
    final desiredCursor = _docLayout.getDesiredCursorAtOffset(cursorOffsetInDocument);

    if (desiredCursor != null && desiredCursor != _cursorStyle.value) {
      _cursorStyle.value = desiredCursor;
    } else if (desiredCursor == null && _cursorStyle.value != SystemMouseCursors.basic) {
      _cursorStyle.value = SystemMouseCursors.basic;
    }
  }

  Offset _getViewportOffsetFromGlobal(Offset globalOffset) {
    return _viewport.globalToLocal(globalOffset);
  }

  Offset _getInteractorOffsetFromGlobalOffset(Offset globalOffset) {
    final interactorBox = context.findRenderObject() as RenderBox;
    return interactorBox.globalToLocal(globalOffset);
  }

  Offset _getDocOffsetFromGlobalOffset(Offset globalOffset) {
    return _docLayout.getDocumentOffsetFromAncestorOffset(globalOffset);
  }

  // ------ scrolling -------
  /// We prevent SingleChildScrollView from processing mouse events because
  /// it scrolls by drag by default, which we don't want. However, we do
  /// still want mouse scrolling. This method re-implements a primitive
  /// form of mouse scrolling.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final newScrollOffset =
          (_scrollPosition.pixels + event.scrollDelta.dy).clamp(0.0, _scrollPosition.maxScrollExtent);
      _scrollPosition.jumpTo(newScrollOffset);

      _updateDragSelection();
    }
  }

  void _scrollIfNearBoundary() {
    final viewport = _viewport;

    final dragEndInViewport = _getViewportOffsetFromGlobal(_dragEndGlobal!);

    // Compute some useful logging information, if our logger is active.
    if (isLogActive(editorGesturesLog)) {
      final dragEndInDoc = _getDocOffsetFromGlobalOffset(_dragEndGlobal!);
      final docBox = _documentWrapperKey.currentContext!.findRenderObject() as RenderBox;

      final dragEndInInteractor = _getInteractorOffsetFromGlobalOffset(_dragEndGlobal!);
      final interactorBox = context.findRenderObject() as RenderBox;

      editorGesturesLog.finest("Scrolling, if near boundary:");
      editorGesturesLog.finest(" - Has ancestor scrollable: $_hasAncestorScrollable");
      editorGesturesLog.finest(
          ' - Drag end in document: ${dragEndInDoc.dy}, document height: ${docBox.size.height}, top left: ${docBox.localToGlobal(Offset.zero)}');
      editorGesturesLog.finest(
          ' - Drag end in interactor: ${dragEndInInteractor.dy}, interactor height: ${interactorBox.size.height}, top left: ${interactorBox.localToGlobal(Offset.zero)}');
      editorGesturesLog.finest(' - Drag end in viewport: ${dragEndInViewport.dy}, viewport size: ${viewport.size}');
      editorGesturesLog.finest(' - Distance to top of viewport: ${dragEndInViewport.dy}');
      editorGesturesLog.finest(' - Distance to bottom of viewport: ${viewport.size.height - dragEndInViewport.dy}');
      editorGesturesLog.finest(' - Auto-scroll distance: ${widget.dragAutoScrollBoundary.trailing}');
      editorGesturesLog.finest(
          ' - Auto-scroll diff: ${viewport.size.height - dragEndInViewport.dy < widget.dragAutoScrollBoundary.trailing}');
    }

    if (dragEndInViewport.dy < widget.dragAutoScrollBoundary.leading) {
      editorGesturesLog.finest('Metrics say we should try to scroll up');
      _startScrollingUp();
    } else {
      _stopScrollingUp();
    }

    if (viewport.size.height - dragEndInViewport.dy < widget.dragAutoScrollBoundary.trailing) {
      editorGesturesLog.finest('Metrics say we should try to scroll down');
      _startScrollingDown();
    } else {
      _stopScrollingDown();
    }
  }

  void _startScrollingUp() {
    if (_scrollUpOnTick) {
      return;
    }

    editorGesturesLog.finest('Starting to auto-scroll up');
    _scrollUpOnTick = true;
    _debugInstrumentation?.autoScrollEdge.value = ViewportEdge.leading;
    _ticker.start();
  }

  void _stopScrollingUp() {
    if (!_scrollUpOnTick) {
      return;
    }

    editorGesturesLog.finest('Stopping auto-scroll up');
    _scrollUpOnTick = false;
    _debugInstrumentation?.autoScrollEdge.value = null;
    _ticker.stop();
  }

  void _scrollUp() {
    if (_dragEndGlobal == null) {
      editorGesturesLog.warning("Tried to scroll up but couldn't because _dragEndGlobal is null");
      assert(_dragEndGlobal != null);
      return;
    }

    if (_scrollPosition.pixels <= 0) {
      editorGesturesLog.finest("Tried to scroll up but the scroll position is already at the top");
      return;
    }

    editorGesturesLog.finest("Scrolling up on tick");

    final dragEndInViewport = _getViewportOffsetFromGlobal(_dragEndGlobal!); // + ancestorScrollableDragEndAdjustment;
    final leadingScrollBoundary = widget.dragAutoScrollBoundary.leading;
    final gutterAmount = dragEndInViewport.dy.clamp(0.0, leadingScrollBoundary);
    final speedPercent = 1.0 - (gutterAmount / leadingScrollBoundary);
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent)!;

    _scrollPosition.jumpTo(_scrollPosition.pixels - scrollAmount);

    // By changing the scroll offset, we may have changed the content
    // selected by the user's current finger/mouse position. Update the
    // document selection calculation.
    _updateDragSelection();
  }

  void _startScrollingDown() {
    if (_scrollDownOnTick) {
      return;
    }

    editorGesturesLog.finest('Starting to auto-scroll down');
    _scrollDownOnTick = true;
    _debugInstrumentation?.autoScrollEdge.value = ViewportEdge.trailing;
    _ticker.start();
  }

  void _stopScrollingDown() {
    if (!_scrollDownOnTick) {
      return;
    }

    editorGesturesLog.finest('Stopping auto-scroll down');
    _scrollDownOnTick = false;
    _debugInstrumentation?.autoScrollEdge.value = null;
    _ticker.stop();
  }

  void _scrollDown() {
    if (_dragEndGlobal == null) {
      editorGesturesLog.warning("Tried to scroll down but couldn't because _dragEndInViewport is null");
      assert(_dragEndGlobal != null);
      return;
    }

    if (_scrollPosition.pixels >= _scrollPosition.maxScrollExtent) {
      editorGesturesLog.finest("Tried to scroll down but the scroll position is already beyond the max");
      return;
    }

    editorGesturesLog.finest("Scrolling down on tick");

    final dragEndInViewport = _getViewportOffsetFromGlobal(_dragEndGlobal!); // + ancestorScrollableDragEndAdjustment;
    final trailingScrollBoundary = widget.dragAutoScrollBoundary.trailing;
    final viewportBox = _viewport;
    final gutterAmount = (viewportBox.size.height - dragEndInViewport.dy).clamp(0.0, trailingScrollBoundary);
    final speedPercent = 1.0 - (gutterAmount / trailingScrollBoundary);
    editorGesturesLog.finest("Speed percent: $speedPercent");
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent)!;

    editorGesturesLog.finest("Jumping from ${_scrollPosition.pixels} to ${_scrollPosition.pixels + scrollAmount}");
    _scrollPosition.jumpTo(_scrollPosition.pixels + scrollAmount);

    // By changing the scroll offset, we may have changed the content
    // selected by the user's current finger/mouse position. Update the
    // document selection calculation.
    _updateDragSelection();
  }

  void _onTick(elapsedTime) {
    if (_scrollUpOnTick) {
      _scrollUp();
    }
    if (_scrollDownOnTick) {
      _scrollDown();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ancestorScrollable = Scrollable.of(context);
    _ancestorScrollPosition = ancestorScrollable?.position;

    return Stack(
      children: [
        // Use a LayoutBuilder to get the max height of the editor,
        // so that we can expand the gesture region to take up all
        // available space.
        LayoutBuilder(builder: (context, constraints) {
          return _buildScroller(
            addScrollView: ancestorScrollable == null,
            child: _buildCursorStyle(
              child: _buildGestureInput(
                child: _buildDocumentContainer(
                  viewportHeight: constraints.maxHeight,
                  document: widget.child,
                ),
              ),
            ),
          );
        }),
        if (widget.showDebugPaint)
          ..._buildScrollingDebugPaint(
            includesScrollView: ancestorScrollable == null,
          ),
      ],
    );
  }

  List<Widget> _buildScrollingDebugPaint({
    required bool includesScrollView,
  }) {
    return [
      if (includesScrollView) ...[
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: widget.dragAutoScrollBoundary.leading.toDouble(),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x440088FF),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: widget.dragAutoScrollBoundary.trailing.toDouble(),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x440088FF),
            ),
          ),
        ),
      ],
    ];
  }

  Widget _buildScroller({
    required bool addScrollView,
    required Widget child,
  }) {
    return addScrollView
        ? SizedBox.expand(
            // If there is no ancestor scrollable then we want the gesture area
            // to fill all available height. If there is a scrollable ancestor,
            // then expanding vertically would cause an infinite height, so in that
            // case we let the gesture area take up whatever it can, naturally.
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const NeverScrollableScrollPhysics(),
                child: child,
              ),
            ),
          )
        : child;
  }

  Widget _buildCursorStyle({
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: _cursorStyle,
      builder: (context, child) {
        return Listener(
          onPointerHover: _onMouseMove,
          child: MouseRegion(
            cursor: _cursorStyle.value,
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildGestureInput({
    required Widget child,
  }) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapSequenceGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapSequenceGestureRecognizer>(
          () => TapSequenceGestureRecognizer(),
          (TapSequenceGestureRecognizer recognizer) {
            recognizer
              ..onTapUp = _onTapUp
              ..onDoubleTapDown = _onDoubleTapDown
              ..onDoubleTap = _onDoubleTap
              ..onTripleTapDown = _onTripleTapDown
              ..onTripleTap = _onTripleTap;
          },
        ),
        PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          () => PanGestureRecognizer(),
          (PanGestureRecognizer recognizer) {
            recognizer
              ..onStart = _onPanStart
              ..onUpdate = _onPanUpdate
              ..onEnd = _onPanEnd
              ..onCancel = _onPanCancel;
          },
        ),
      },
      child: child,
    );
  }

  Widget _buildDocumentContainer({
    required double viewportHeight,
    required Widget document,
  }) {
    // TODO(June, 2022): why is this Center here?
    return Center(
      child: Stack(
        children: [
          ConstrainedBox(
            // The gesture detector needs to respond to gestures outside the
            // document's bounds, when the document is shorter than the viewport.
            // Therefore, we force the gesture detector to be at least as tall as
            // the viewport.
            //
            // The viewport height will be infinite when the editor is placed within
            // another Scrollable. In that case, we allow any height.
            constraints: BoxConstraints(minHeight: viewportHeight < double.infinity ? viewportHeight : 0),
            child: SizedBox(
              key: _documentWrapperKey,
              child: document,
            ),
          ),
          if (widget.showDebugPaint) ..._buildDebugPaintInDocSpace(),
        ],
      ),
    );
  }

  List<Widget> _buildDebugPaintInDocSpace() {
    final dragStartInDoc = _dragStartGlobal != null ? _getDocOffsetFromGlobalOffset(_dragStartGlobal!) : null;
    final dragEndInDoc = _dragEndGlobal != null ? _getDocOffsetFromGlobalOffset(_dragEndGlobal!) : null;

    return [
      if (dragStartInDoc != null)
        Positioned(
          left: dragStartInDoc.dx,
          top: dragStartInDoc.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0088FF),
              ),
            ),
          ),
        ),
      if (dragEndInDoc != null)
        Positioned(
          left: dragEndInDoc.dx,
          top: dragEndInDoc.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0088FF),
              ),
            ),
          ),
        ),
      if (dragStartInDoc != null && dragEndInDoc != null)
        Positioned(
          left: min(dragStartInDoc.dx, dragEndInDoc.dx),
          top: min(dragStartInDoc.dy, dragEndInDoc.dy),
          width: (dragEndInDoc.dx - dragStartInDoc.dx).abs(),
          height: (dragEndInDoc.dy - dragStartInDoc.dy).abs(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF0088FF), width: 3),
            ),
          ),
        ),
    ];
  }
}

enum SelectionType {
  position,
  word,
  paragraph,
}

/// Paints a rectangle border around the given `selectionRect`.
class DragRectanglePainter extends CustomPainter {
  DragRectanglePainter({
    this.selectionRect,
    Listenable? repaint,
  }) : super(repaint: repaint);

  final Rect? selectionRect;
  final Paint _selectionPaint = Paint()
    ..color = const Color(0xFFFF0000)
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (selectionRect != null) {
      canvas.drawRect(selectionRect!, _selectionPaint);
    }
  }

  @override
  bool shouldRepaint(DragRectanglePainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
