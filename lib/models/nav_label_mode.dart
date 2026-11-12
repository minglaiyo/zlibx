/// How the bottom navigation bar renders its labels.
///
/// Mirrors legado's NavigationBarDisplayMode:
/// - always: icon and text, always;
/// - auto: text only for the selected item (legado's IconWithSelectedLabel);
/// - never: icons only.
enum NavLabelMode { always, auto, never }
