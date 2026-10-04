/// A remote's way in and out of a single-line text field.
///
/// A text field swallows the arrow keys: Flutter's directional focus stands
/// down while one has focus, so the up and down that move focus everywhere
/// else do nothing there. On a television, with the keyboard put away, that
/// left a remote with no way out of the field - and, in a dialog, no way to
/// its Save.
///
/// While a keyboard is up the arrows are the keyboard's: Android TV's walks
/// its letter grid with all four, and taking them would move focus out of the
/// field and close it mid-word. So the up and down that leave the field are
/// taken only while it is down, and Select - OK on a remote - brings it back,
/// the way a television's own text boxes open theirs. Every other key is
/// left to the field.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A [FocusNode.onKeyEvent] for a single-line text field's own node.
KeyEventResult remoteTextFieldKeys(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final context = node.context;
  if (context == null || !context.mounted || _keyboardUp(context)) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
    node.focusInDirection(
      key == LogicalKeyboardKey.arrowDown
          ? TraversalDirection.down
          : TraversalDirection.up,
    );
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.select && event is KeyDownEvent) {
    context.findAncestorStateOfType<EditableTextState>()?.requestKeyboard();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// Whether a soft keyboard covers part of the window.
///
/// Read off the window rather than [MediaQuery]: a dialog and a [Scaffold]
/// each take the keyboard's inset out of what they hand their children, so a
/// field inside either always sees none.
bool _keyboardUp(BuildContext context) =>
    (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
