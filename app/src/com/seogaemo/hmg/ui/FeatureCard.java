package com.seogaemo.hmg.ui;

import android.content.Context;
import android.graphics.Color;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import com.seogaemo.hmg.R;
import com.seogaemo.hmg.ui.settings.SettingsUi;

/** Full-height Features card: icon, name, optional note, and a bottom status row with its own tap target. */
public final class FeatureCard extends LinearLayout {
    public enum State { LOADING, ON, OFF, APPLYING, RESTART, UNAVAILABLE, UNKNOWN }

    public static final int ICON_BOX = 60;
    public static final int ICON = 34;

    private final LineIcon icon;
    private final ImageView iconView;
    private final TextView name;
    private final TextView note;
    private final LinearLayout statusRow;
    private final LineIcon statusGlyph;
    private final ImageView statusGlyphView;
    private final ProgressBar spinner;
    private final TextView statusLabel;
    private String actionLabel;

    public FeatureCard(Context context, String iconName, String title) {
        super(context);
        setOrientation(VERTICAL);
        int pad = dp(SettingsUi.MD);
        setPadding(pad, pad, pad, pad);

        iconView = new ImageView(context);
        icon = new LineIcon(context, iconName, Theme.MUTED, ICON);
        iconView.setImageDrawable(icon);
        iconView.setScaleType(ImageView.ScaleType.CENTER);
        iconView.setBackgroundDrawable(Theme.shape(context, Theme.RAISED, Color.TRANSPARENT, Theme.CARD_RADIUS));
        addView(iconView, new LayoutParams(dp(ICON_BOX), dp(ICON_BOX)));

        View spacer = new View(context);
        addView(spacer, new LayoutParams(-1, 0, 1));

        name = Theme.text(context, title, 23, Theme.WHITE, true);
        name.setMaxLines(2);
        Theme.keepAll(name);
        name.setGravity(Gravity.BOTTOM);
        addView(name, new LayoutParams(-1, -2));

        note = Theme.text(context, "", 16, Theme.MUTED, false);
        note.setSingleLine(true);
        note.setEllipsize(TextUtils.TruncateAt.END);
        note.setVisibility(INVISIBLE);
        LayoutParams noteParams = new LayoutParams(-1, dp(24));
        noteParams.topMargin = dp(SettingsUi.XS);
        addView(note, noteParams);

        LayoutParams lineParams = new LayoutParams(-1, dp(1));
        lineParams.topMargin = dp(SettingsUi.MD);
        addView(Theme.hairline(context), lineParams);
        statusRow = new LinearLayout(context);
        statusRow.setOrientation(HORIZONTAL);
        statusRow.setGravity(Gravity.CENTER_VERTICAL);
        statusGlyph = new LineIcon(context, "power", Theme.MUTED, 22);
        statusGlyphView = new ImageView(context);
        statusGlyphView.setImageDrawable(statusGlyph);
        statusGlyphView.setScaleType(ImageView.ScaleType.CENTER);
        statusRow.addView(statusGlyphView, new LayoutParams(dp(24), dp(24)));
        spinner = new ProgressBar(context);
        spinner.setIndeterminate(true);
        spinner.setVisibility(GONE);
        statusRow.addView(spinner, new LayoutParams(dp(24), dp(24)));
        statusLabel = Theme.text(context, "", 19, Theme.MUTED, true);
        statusLabel.setSingleLine(true);
        LayoutParams labelParams = new LayoutParams(0, -2, 1);
        labelParams.leftMargin = dp(SettingsUi.SM);
        statusRow.addView(statusLabel, labelParams);
        addView(statusRow, new LayoutParams(-1, dp(56)));

        setState(State.LOADING, null, false);
    }

    public void setListeners(OnClickListener body, OnClickListener status) {
        setOnClickListener(body);
        statusRow.setOnClickListener(status);
        statusRow.setClickable(status != null);
    }

    /** One-shot module: the status row is the action button, labelled with the module's own text. */
    public void setActionLabel(String label) { actionLabel = label; }

    public void setState(State state, String noteText, boolean noteIsError) {
        Context context = getContext();
        boolean on = state == State.ON && actionLabel == null;
        boolean dimmed = state == State.UNAVAILABLE || state == State.UNKNOWN;
        setBackgroundDrawable(Theme.selectable(context, Theme.SURFACE, on ? Theme.BLUE : Theme.HAIRLINE,
                Theme.CARD_RADIUS, false));
        icon.setColor(on ? Theme.BLUE : Theme.MUTED);
        iconView.setAlpha(dimmed ? 0.55f : 1f);
        name.setTextColor(on ? Theme.WHITE : Theme.DIM);
        name.setAlpha(dimmed ? 0.55f : 1f);
        if (noteText == null || noteText.length() == 0) {
            note.setVisibility(INVISIBLE);
        } else {
            note.setText(noteText);
            note.setTextColor(noteIsError ? Theme.ERROR : Theme.MUTED);
            note.setVisibility(VISIBLE);
        }
        int labelRes;
        int color;
        if (state == State.ON) { labelRes = R.string.state_on; color = Theme.BLUE; }
        else if (state == State.OFF) { labelRes = R.string.state_off; color = Theme.MUTED; }
        else if (state == State.APPLYING) { labelRes = R.string.state_applying; color = Theme.WARNING; }
        else if (state == State.RESTART) { labelRes = R.string.state_restart; color = Theme.WARNING; }
        else if (state == State.UNAVAILABLE) { labelRes = R.string.state_unavailable; color = Theme.MUTED; }
        else if (state == State.UNKNOWN) { labelRes = R.string.state_unknown; color = Theme.MUTED; }
        else { labelRes = R.string.state_loading; color = Theme.MUTED; }
        if (actionLabel != null && (state == State.ON || state == State.OFF)) {
            statusLabel.setText(actionLabel);
            color = Theme.BLUE;
        } else statusLabel.setText(context.getString(labelRes));
        statusLabel.setTextColor(color);
        statusGlyph.setColor(color);
        boolean busy = state == State.APPLYING || state == State.LOADING;
        spinner.setVisibility(busy ? VISIBLE : GONE);
        statusGlyphView.setVisibility(busy ? GONE : VISIBLE);
        statusRow.setBackgroundDrawable(Theme.selectable(context, Theme.SURFACE, Color.TRANSPARENT,
                Theme.BUTTON_RADIUS, false));
    }

    private int dp(int value) { return Theme.dp(getContext(), value); }
}
