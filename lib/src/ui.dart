import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'service.dart';

/// Ready-made spell-check configuration and menus for text fields.
///
/// ```dart
/// TextField(
///   spellCheckConfiguration: UniversalSpellCheck.configuration(),
///   contextMenuBuilder: UniversalSpellCheck.contextMenuBuilder,
/// )
/// ```
abstract final class UniversalSpellCheck {
  /// Returns a [SpellCheckConfiguration] that works on every platform.
  ///
  /// * [service]: defaults to the shared [UniversalSpellCheckService.instance]
  ///   (reuse one service; do not create a new one in every `build`).
  /// * [misspelledTextStyle]: defaults to [misspelledTextStyle].
  /// * [spellCheckSuggestionsToolbarBuilder]: defaults to
  ///   [suggestionsToolbarBuilder].
  static SpellCheckConfiguration configuration({
    SpellCheckService? service,
    TextStyle? misspelledTextStyle,
    Color? misspelledSelectionColor,
    EditableTextContextMenuBuilder? spellCheckSuggestionsToolbarBuilder,
  }) {
    return SpellCheckConfiguration(
      spellCheckService: service ?? UniversalSpellCheckService.instance,
      misspelledTextStyle:
          misspelledTextStyle ?? UniversalSpellCheck.misspelledTextStyle,
      misspelledSelectionColor: misspelledSelectionColor,
      spellCheckSuggestionsToolbarBuilder:
          spellCheckSuggestionsToolbarBuilder ?? suggestionsToolbarBuilder,
    );
  }

  /// The platform's usual misspelling mark: Cupertino's red dotted
  /// underline on iOS/macOS, Material's red wavy underline elsewhere.
  static TextStyle get misspelledTextStyle => switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.macOS => CupertinoTextField.cupertinoMisspelledTextStyle,
    _ => TextField.materialMisspelledTextStyle,
  };

  /// Toolbar shown when Flutter asks for spell-check suggestions (a tap on
  /// a misspelled word on Android/iOS, or [EditableTextState.showSpellCheckSuggestionsToolbar]).
  ///
  /// Uses the native-looking Material/Cupertino suggestion toolbars on
  /// Android/iOS and an adaptive menu with the suggestions elsewhere.
  static Widget suggestionsToolbarBuilder(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return CupertinoSpellCheckSuggestionsToolbar.editableText(
          editableTextState: editableTextState,
        );
      case TargetPlatform.android:
        return SpellCheckSuggestionsToolbar.editableText(
          editableTextState: editableTextState,
        );
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        final List<ContextMenuButtonItem> items = suggestionButtonItems(
          editableTextState,
        );
        if (items.isEmpty) return const SizedBox.shrink();
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: items,
        );
    }
  }

  /// A context menu builder (for `TextField.contextMenuBuilder`) that puts
  /// the suggestions for the misspelled word under the cursor, plus an
  /// "Ignore" item, in front of the usual cut/copy/paste items.
  ///
  /// This is how desktop and web users reach suggestions (right-click),
  /// because Flutter only opens its spell-check toolbar on tap on
  /// Android/iOS. On the web, call [useFlutterContextMenuOnWeb] first so
  /// the browser's own menu does not replace Flutter's.
  static Widget contextMenuBuilder(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    return contextMenuBuilderWith()(context, editableTextState);
  }

  /// Like [contextMenuBuilder] with options: [ignoreLabel] (localise it),
  /// [showIgnore] and [maxSuggestions] shown in the menu.
  static EditableTextContextMenuBuilder contextMenuBuilderWith({
    String ignoreLabel = 'Ignore',
    bool showIgnore = true,
    int maxSuggestions = 5,
  }) {
    return (BuildContext context, EditableTextState editableTextState) {
      final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
        ...suggestionButtonItems(
          editableTextState,
          ignoreLabel: ignoreLabel,
          showIgnore: showIgnore,
          maxSuggestions: maxSuggestions,
        ),
        ...editableTextState.contextMenuButtonItems,
      ];
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: items,
      );
    };
  }

  /// Disables the browser's context menu on the web so that Flutter's menu
  /// (and with it [contextMenuBuilder]'s suggestions) appears on
  /// right-click. Does nothing on other platforms.
  static Future<void> useFlutterContextMenuOnWeb() async {
    if (kIsWeb && BrowserContextMenu.enabled) {
      await BrowserContextMenu.disableContextMenu();
    }
  }

  /// Menu items for the misspelled word at the cursor/selection of
  /// [editableTextState]: one per suggestion, then "Ignore" (when the
  /// field's service is a [UniversalSpellCheckService] and [showIgnore]).
  /// Empty when the cursor is not on a misspelled word.
  static List<ContextMenuButtonItem> suggestionButtonItems(
    EditableTextState editableTextState, {
    String ignoreLabel = 'Ignore',
    bool showIgnore = true,
    int maxSuggestions = 5,
  }) {
    final SuggestionSpan? span = misspelledSpanAtSelection(editableTextState);
    if (span == null ||
        editableTextState.widget.readOnly ||
        editableTextState.widget.obscureText) {
      return const <ContextMenuButtonItem>[];
    }
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      for (final String suggestion in span.suggestions.take(maxSuggestions))
        ContextMenuButtonItem(
          label: suggestion,
          onPressed: () =>
              replaceMisspelled(editableTextState, span.range, suggestion),
        ),
    ];
    final SpellCheckService? service =
        editableTextState.widget.spellCheckConfiguration?.spellCheckService;
    if (showIgnore && service is UniversalSpellCheckService) {
      items.add(
        ContextMenuButtonItem(
          label: ignoreLabel,
          onPressed: () => ignoreMisspelled(editableTextState, service, span),
        ),
      );
    }
    return items;
  }

  /// The [SuggestionSpan] under the selection of [editableTextState], if
  /// the text there is still the text that was spell checked.
  static SuggestionSpan? misspelledSpanAtSelection(
    EditableTextState editableTextState,
  ) {
    final TextEditingValue value = editableTextState.textEditingValue;
    final TextSelection selection = value.selection;
    if (!selection.isValid) return null;
    final SpellCheckResults? results = editableTextState.spellCheckResults;
    if (results == null) return null;
    final SuggestionSpan? span =
        editableTextState.findSuggestionSpanAtCursorIndex(
          selection.baseOffset,
        ) ??
        editableTextState.findSuggestionSpanAtCursorIndex(
          selection.extentOffset,
        );
    if (span == null) return null;
    final TextRange r = span.range;
    final String checked = results.spellCheckedText;
    if (r.end > value.text.length ||
        r.end > checked.length ||
        value.text.substring(r.start, r.end) !=
            checked.substring(r.start, r.end)) {
      // The text moved since it was checked; the range is stale.
      return null;
    }
    return span;
  }

  /// Replaces [range] of the field's text with [replacement] as a user
  /// edit (so undo and `onChanged` work) and hides the toolbar.
  static void replaceMisspelled(
    EditableTextState editableTextState,
    TextRange range,
    String replacement,
  ) {
    if (!editableTextState.mounted) return;
    final TextEditingValue value = editableTextState.textEditingValue;
    if (range.end > value.text.length) return;
    final TextEditingValue newValue = value.replaced(range, replacement);
    editableTextState.userUpdateTextEditingValue(
      newValue.copyWith(
        selection: TextSelection.collapsed(
          offset: range.start + replacement.length,
        ),
      ),
      SelectionChangedCause.toolbar,
    );
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      if (editableTextState.mounted) {
        editableTextState.bringIntoView(
          editableTextState.textEditingValue.selection.extent,
        );
      }
    }, debugLabel: 'UniversalSpellCheck.bringIntoView');
    editableTextState.hideToolbar();
  }

  /// Adds the word of [span] to [service]'s ignore list and removes its
  /// marks from the field immediately.
  static void ignoreMisspelled(
    EditableTextState editableTextState,
    UniversalSpellCheckService service,
    SuggestionSpan span,
  ) {
    if (!editableTextState.mounted) return;
    final SpellCheckResults? results = editableTextState.spellCheckResults;
    if (results == null) return;
    final String text = results.spellCheckedText;
    final String word = text.substring(span.range.start, span.range.end);
    service.ignoreWord(word);
    final String lower = word.toLowerCase();
    editableTextState.spellCheckResults = SpellCheckResults(
      text,
      <SuggestionSpan>[
        for (final SuggestionSpan s in results.suggestionSpans)
          if (s.range.end > text.length ||
              text.substring(s.range.start, s.range.end).toLowerCase() != lower)
            s,
      ],
    );
    editableTextState.hideToolbar();
    // Rebuild so EditableText re-renders its text span without the marks.
    (editableTextState.context as Element).markNeedsBuild();
  }
}
