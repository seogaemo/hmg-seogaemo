package com.seogaemo.hmg.ui;

import android.content.Context;
import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import com.seogaemo.hmg.R;
import com.seogaemo.hmg.ui.settings.SettingsUi;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Features tab: full-height cards in width-derived columns, paged sideways, with the add card last. */
public final class FeaturesView extends LinearLayout {
    public interface Listener {
        void openDetail(Feature feature);
        void tapStatus(Feature feature);
        void add();
        void restartLater();
        void restartNow();
    }

    public static final class Entry {
        public final Feature feature;
        public FeatureCard.State state = FeatureCard.State.LOADING;
        public String note;
        public boolean noteError;
        public boolean statusTappable;
        public Entry(Feature feature) { this.feature = feature; }
    }

    private static final int MIN_CARD = 184;
    private static final int GAP = 12;

    private final Listener listener;
    private final RestartBar restartBar;
    private final Pager pager;
    private final LinearLayout dots;
    private final Map<String, FeatureCard> cards = new HashMap<String, FeatureCard>();
    private List<Entry> entries = new ArrayList<Entry>();
    private int builtWidth;

    public FeaturesView(Context context, final Listener listener) {
        super(context);
        this.listener = listener;
        setOrientation(VERTICAL);
        setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.MD), dp(SettingsUi.PAGE), dp(SettingsUi.XS));
        restartBar = new RestartBar(context, new OnClickListener() {
            public void onClick(View view) { listener.restartLater(); }
        }, new OnClickListener() {
            public void onClick(View view) { listener.restartNow(); }
        });
        restartBar.setVisibility(GONE);
        addView(restartBar, RestartBar.layoutParams(context));
        pager = new Pager(context);
        addView(pager, new LayoutParams(-1, 0, 1));
        dots = new LinearLayout(context);
        dots.setGravity(Gravity.CENTER);
        addView(dots, new LayoutParams(-1, dp(32)));
        pager.setPageListener(new Runnable() { public void run() { updateDots(); } });
    }

    public void setRestartPending(boolean pending) {
        restartBar.setVisibility(pending ? VISIBLE : GONE);
    }

    public void setEntries(List<Entry> list) {
        entries = new ArrayList<Entry>(list);
        builtWidth = 0;
        rebuild();
    }

    public void update(Entry entry) {
        FeatureCard card = cards.get(entry.feature.id);
        if (card != null) bind(card, entry);
    }

    public boolean shows(String id) { return cards.containsKey(id); }

    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        if (w != builtWidth) rebuild();
    }

    private void rebuild() {
        int width = getWidth() - getPaddingLeft() - getPaddingRight();
        if (width <= 0) return;
        builtWidth = getWidth();
        Context context = getContext();
        int columns = Math.max(2, (width + dp(GAP)) / (dp(MIN_CARD) + dp(GAP)));
        int total = entries.size() + 1;
        int pageCount = Math.max(1, (total + columns - 1) / columns);
        int current = pager.page();
        pager.clearPages();
        cards.clear();
        for (int p = 0; p < pageCount; p++) {
            LinearLayout row = new LinearLayout(context);
            row.setOrientation(HORIZONTAL);
            for (int slot = 0; slot < columns; slot++) {
                int index = p * columns + slot;
                View cell;
                if (index < entries.size()) {
                    final Entry entry = entries.get(index);
                    FeatureCard card = new FeatureCard(context, entry.feature.icon, entry.feature.name);
                    if (entry.feature.isAction()) card.setActionLabel(entry.feature.installed.actionLabel());
                    bind(card, entry);
                    cards.put(entry.feature.id, card);
                    cell = card;
                } else if (index == entries.size()) {
                    cell = addCard();
                } else {
                    cell = new View(context);
                }
                LayoutParams cellParams = new LayoutParams(0, -1, 1);
                if (slot > 0) cellParams.leftMargin = dp(GAP);
                row.addView(cell, cellParams);
            }
            pager.addPage(row);
        }
        pager.setPage(Math.min(current, pageCount - 1));
        pager.post(new Runnable() { public void run() { pager.syncWidths(); } });
        updateDots();
    }

    private void bind(FeatureCard card, final Entry entry) {
        card.setState(entry.state, entry.note, entry.noteError);
        card.setListeners(new OnClickListener() {
            public void onClick(View view) { listener.openDetail(entry.feature); }
        }, entry.statusTappable ? new OnClickListener() {
            public void onClick(View view) { listener.tapStatus(entry.feature); }
        } : null);
    }

    private View addCard() {
        Context context = getContext();
        LinearLayout card = new LinearLayout(context);
        card.setOrientation(VERTICAL);
        card.setGravity(Gravity.CENTER);
        card.setBackgroundDrawable(Theme.selectable(context, Theme.SURFACE, Theme.HAIRLINE, Theme.CARD_RADIUS, false));
        android.widget.ImageView glyph = new android.widget.ImageView(context);
        glyph.setScaleType(android.widget.ImageView.ScaleType.CENTER);
        glyph.setImageDrawable(new LineIcon(context, "plus", Theme.MUTED, FeatureCard.ICON));
        glyph.setBackgroundDrawable(Theme.shape(context, Theme.RAISED, Color.TRANSPARENT, Theme.CARD_RADIUS));
        card.addView(glyph, new LayoutParams(dp(FeatureCard.ICON_BOX), dp(FeatureCard.ICON_BOX)));
        android.widget.TextView label = Theme.text(context, context.getString(R.string.features_add), 22, Theme.DIM, true);
        LayoutParams labelParams = new LayoutParams(-2, -2);
        labelParams.topMargin = dp(SettingsUi.MD);
        card.addView(label, labelParams);
        card.setOnClickListener(new OnClickListener() { public void onClick(View view) { listener.add(); } });
        return card;
    }

    private void updateDots() {
        dots.removeAllViews();
        int count = pager.pageCount();
        if (count <= 1) return;
        for (int i = 0; i < count; i++) {
            final int target = i;
            View dot = new View(getContext());
            boolean selected = i == pager.page();
            dot.setBackgroundDrawable(Theme.shape(getContext(), selected ? Theme.BLUE : Theme.HAIRLINE,
                    Color.TRANSPARENT, 20));
            LayoutParams params = new LayoutParams(dp(selected ? 12 : 8), dp(selected ? 12 : 8));
            params.leftMargin = dp(SettingsUi.XS);
            params.rightMargin = dp(SettingsUi.XS);
            dots.addView(dot, params);
            dot.setOnClickListener(new OnClickListener() { public void onClick(View view) { pager.setPage(target); } });
        }
    }

    private int dp(int value) { return Theme.dp(getContext(), value); }
}
