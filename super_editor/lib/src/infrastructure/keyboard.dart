import 'package:flutter/widgets.dart';

import 'platform_detector.dart';

/// Widget that responds to keyboard events for a given [focusNode] without
/// necessarily re-parenting the [focusNode].
///
/// The [focusNode] is only re-parented if its parent is `null`.
///
/// The traditional [Focus] widget provides an `onKey` property, but that widget
/// automatically re-parents the [FocusNode] based on the structure of the widget
/// tree. Re-parenting is a problem in some situations, e.g., a popover toolbar
/// that appears while editing a document. The toolbar and the document are on
/// different branches of the widget tree, but they need to share focus. That shared
/// focus is impossible when the [Focus] widget forces re-parenting. The
/// [KeyboardFocus] widget provides an [onKey] property without re-parenting the
/// given [focusNode].
class KeyboardFocus extends StatefulWidget {
  const KeyboardFocus({
    Key? key,
    required this.focusNode,
    required this.onKey,
    required this.child,
  }) : super(key: key);

  /// The [FocusNode] that sends key events to [onKey].
  final FocusNode focusNode;

  /// The callback invoked whenever [focusNode] receives key events.
  final FocusOnKeyCallback onKey;

  /// The child of this widget.
  final Widget child;

  @override
  State<KeyboardFocus> createState() => _KeyboardFocusState();
}

class _KeyboardFocusState extends State<KeyboardFocus> {
  late FocusAttachment _keyboardFocusAttachment;

  @override
  void initState() {
    super.initState();
    _keyboardFocusAttachment = widget.focusNode.attach(context, onKey: widget.onKey);
  }

  @override
  void didUpdateWidget(KeyboardFocus oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode || widget.onKey != oldWidget.onKey) {
      _keyboardFocusAttachment.detach();
      _keyboardFocusAttachment = widget.focusNode.attach(context, onKey: widget.onKey);
      _reparentIfMissingParent();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reparentIfMissingParent();
  }

  @override
  void dispose() {
    _keyboardFocusAttachment.detach();
    super.dispose();
  }

  void _reparentIfMissingParent() {
    if (widget.focusNode.parent == null) {
      _keyboardFocusAttachment.reparent();
    }
  }

  @override
  Widget build(BuildContext context) {
    _reparentIfMissingParent();

    return widget.child;
  }
}

extension PrimaryShortcutKey on RawKeyEvent {
  bool get isPrimaryShortcutKeyPressed =>
      (Platform.instance.isMac && isMetaPressed) || (!Platform.instance.isMac && isControlPressed);
}

/// On web, Flutter reports control character labels as
/// the [RawKeyEvent.character], which we don't want.
/// Until Flutter fixes the problem, this blacklist
/// identifies the keys that we should ignore for the
/// purpose of text/character entry.
const webBugBlacklistCharacters = {
  'Dead',
  'Shift',
  'Alt',
  'Escape',
  'CapsLock',
  'PageUp',
  'PageDown',
  'Home',
  'End',
  'Control',
  'Meta',
  'Enter',
  'Backspace',
  'Delete',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
  'Num Lock',
  'Scroll Lock',
  'Insert',
  'Paste',
  'Print Screen',
  'Power',
};
