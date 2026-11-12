# ergon boot splash: the stacked logo (logo.png, rendered by bin/ergon-plymouth
# from logo/ergon-lockup-stacked-light.svg in the palette's foreground), and the
# disk passphrase prompt under it.
# Rendered by bin/ergon-plymouth from the active palette (the colour tokens become
# "r, g, b" in 0..1). Not yet approved on screen; iterate here. ASCII only:
# the label plugin draws boxes for anything else (VM screenshot, 2026-10-23).

Window.SetBackgroundTopColor(@COOL_BG0@);
Window.SetBackgroundBottomColor(@COOL_BG0@);

global.font_text = "JetBrainsMono Nerd Font 14";
global.font_dots = "JetBrainsMono Nerd Font 20";

# The full-size logo; the scaled copy is what is drawn (see layout()).
logo.full = Image("logo.png");
logo.image = logo.full;
logo.sprite = Sprite(logo.image);

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
  # A quarter of the screen's height, never above the image's own size, never
  # below 160 px. The prompt hangs under it, so the pair stays centred as a
  # block rather than the logo sitting dead centre with the prompt off-screen.
  logo_h = global.layout_h / 4;
  if (logo_h < 160) logo_h = 160;
  if (logo_h > logo.full.GetHeight()) logo_h = logo.full.GetHeight();
  logo_w = Math.Int(logo.full.GetWidth() * logo_h / logo.full.GetHeight());
  logo.image = logo.full.Scale(logo_w, Math.Int(logo_h));
  logo.sprite.SetImage(logo.image);
  global.logo_y = global.layout_h / 2 - logo.image.GetHeight() * 0.8;
  logo.sprite.SetPosition(center_x(logo.image), global.logo_y, 10);
  global.prompt_y = global.logo_y + logo.image.GetHeight() + 40;
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
    s = s + "* ";
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
