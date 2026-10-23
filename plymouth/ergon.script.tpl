# ergon boot splash: the wordmark, and the disk passphrase prompt under it.
# Rendered by bin/ergon-plymouth from the active palette (the colour tokens become
# "r, g, b" in 0..1). Not yet approved on screen; iterate here.

Window.SetBackgroundTopColor(@COOL_BG0@);
Window.SetBackgroundBottomColor(@COOL_BG0@);

global.font_mark = "JetBrainsMono Nerd Font 48";
global.font_text = "JetBrainsMono Nerd Font 14";
global.font_dots = "JetBrainsMono Nerd Font 20";

mark.image = Image.Text("ergon", @COOL_FG0@, 1, global.font_mark);
mark.sprite = Sprite(mark.image);
rule.image = Image.Text("────", @COOL_ACCENT@, 1, global.font_text);
rule.sprite = Sprite(rule.image);

prompt.sprite = Sprite();
dots.sprite = Sprite();
message.sprite = Sprite();
global.prompt_shown = 0;

global.layout_w = 0;
global.layout_h = 0;

fun center_x(image) {
  return global.layout_w / 2 - image.GetWidth() / 2;
}

fun layout() {
  global.layout_w = Window.GetWidth();
  global.layout_h = Window.GetHeight();
  global.mark_y = global.layout_h / 2 - mark.image.GetHeight();
  mark.sprite.SetPosition(center_x(mark.image), global.mark_y, 10);
  global.rule_y = global.mark_y + mark.image.GetHeight() + 4;
  rule.sprite.SetPosition(center_x(rule.image), global.rule_y, 10);
  global.prompt_y = global.rule_y + rule.image.GetHeight() + 36;
  global.dots_y = global.prompt_y + 34;
  if (global.prompt_shown == 1) {
    prompt.sprite.SetPosition(center_x(prompt.image), global.prompt_y, 10);
    dots.sprite.SetPosition(center_x(dots.image), global.dots_y, 10);
  }
}
layout();

# A display can appear after this script starts; follow its size.
fun refresh_callback() {
  if (Window.GetWidth() != global.layout_w || Window.GetHeight() != global.layout_h) {
    layout();
  }
}
Plymouth.SetRefreshFunction(refresh_callback);

fun display_password_callback(text, bullets) {
  global.prompt_shown = 1;
  prompt.image = Image.Text(text, @COOL_DIM@, 1, global.font_text);
  prompt.sprite.SetImage(prompt.image);
  n = bullets;
  if (n > 24) n = 24;
  s = "";
  for (i = 0; i < n; i++) {
    s = s + "• ";
  }
  s = s + "_";
  dots.image = Image.Text(s, @COOL_ACCENT@, 1, global.font_dots);
  dots.sprite.SetImage(dots.image);
  prompt.sprite.SetOpacity(1);
  dots.sprite.SetOpacity(1);
  layout();
}
Plymouth.SetDisplayPasswordFunction(display_password_callback);

fun display_normal_callback() {
  global.prompt_shown = 0;
  prompt.sprite.SetOpacity(0);
  dots.sprite.SetOpacity(0);
}
Plymouth.SetDisplayNormalFunction(display_normal_callback);

fun display_message_callback(text) {
  message.image = Image.Text(text, @COOL_DIMMER@, 1, global.font_text);
  message.sprite.SetImage(message.image);
  message.sprite.SetPosition(center_x(message.image), global.layout_h - 80, 10);
  message.sprite.SetOpacity(1);
}
Plymouth.SetDisplayMessageFunction(display_message_callback);

fun hide_message_callback(text) {
  message.sprite.SetOpacity(0);
}
Plymouth.SetHideMessageFunction(hide_message_callback);
