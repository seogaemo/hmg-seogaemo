package com.seogaemo.hmg.module;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** An installed module package as reported by `module describe`; no Android types. */
public final class InstalledModule {
    public final String id;
    public final String version;
    public final String source;
    public final String restart;
    public final boolean rebootRestore;
    /** App-drawn icon name from the fixed set in the contract; "box" when undeclared. */
    public final String icon;
    /** One-shot module (`kind=action`): no on/off state, one button runs it. */
    public final boolean action;
    /** Name of the first `button` block of ui.txt, the one a one-shot module's card runs; null if none. */
    public final String actionName;
    public final String[] depends;
    public final String[] excludes;
    public final String[] uses;
    public final List<Module.Setting> settings;
    public final List<String> uiBlocks;
    public final Map<String, String> strings;
    /** The raw `module describe` values, kept so the app can cache and re-parse them. */
    public final Map<String, String> info;

    private InstalledModule(String id, Map<String, String> info) {
        this.id = id;
        this.info = Collections.unmodifiableMap(new HashMap<String, String>(info));
        version = value(info, "version");
        source = value(info, "source");
        restart = value(info, "restart");
        rebootRestore = "reboot".equals(info.get("restore"));
        String declaredIcon = info.get("icon");
        icon = declaredIcon == null || declaredIcon.length() == 0 ? "box" : declaredIcon;
        action = "action".equals(info.get("kind"));
        depends = csv(info.get("depends"));
        excludes = csv(info.get("excludes"));
        uses = csv(info.get("uses"));
        TreeMap<Integer, Module.Setting> foundSettings = new TreeMap<Integer, Module.Setting>();
        TreeMap<Integer, String> foundUi = new TreeMap<Integer, String>();
        Map<String, String> foundStrings = new HashMap<String, String>();
        for (Map.Entry<String, String> entry : info.entrySet()) {
            String key = entry.getKey();
            if (key.startsWith("setting_")) {
                Integer index = index(key.substring(8));
                Module.Setting setting = setting(entry.getValue());
                if (index != null && setting != null) foundSettings.put(index, setting);
            } else if (key.startsWith("ui_")) {
                Integer index = index(key.substring(3));
                if (index != null) foundUi.put(index, entry.getValue());
            } else if (key.startsWith("str_") && key.length() > 4) {
                foundStrings.put(key.substring(4), entry.getValue());
            }
        }
        settings = Collections.unmodifiableList(new ArrayList<Module.Setting>(foundSettings.values()));
        uiBlocks = Collections.unmodifiableList(new ArrayList<String>(foundUi.values()));
        strings = Collections.unmodifiableMap(foundStrings);
        String firstButton = null;
        for (String block : uiBlocks) {
            String[] tokens = block.trim().split("\\s+");
            if (tokens.length == 0 || !"button".equals(tokens[0])) continue;
            for (String token : tokens) if (token.startsWith("name=")) { firstButton = token.substring(5); break; }
            if (firstButton != null) break;
        }
        actionName = firstButton;
    }

    /** Null when the result is not a successful description of this module. */
    public static InstalledModule parse(String id, RootResult describe) {
        if (describe == null || describe.exitCode != 0 || !"on".equals(describe.state)) return null;
        if (!RootClient.validId(id) || describe.info.get("version") == null) return null;
        return new InstalledModule(id, describe.info);
    }

    /** Display text for a `@key` reference or a plain key; the key itself when missing. */
    public String text(String key) {
        String name = key.startsWith("@") ? key.substring(1) : key;
        String value = strings.get(name);
        return value == null ? name : value;
    }

    public String name() { return text("name"); }
    public String summary() { return text("summary"); }
    /** Card and detail button text of a one-shot module: `action_label`, else the module name. */
    public String actionLabel() { return strings.containsKey("action_label") ? text("action_label") : name(); }
    /** Confirm question of a one-shot module: `action_confirm`, else the button label. */
    public String actionConfirm() { return strings.containsKey("action_confirm") ? text("action_confirm") : actionLabel(); }

    static Module.Setting setting(String declaration) {
        String[] parts = declaration.split(":", -1);
        if (parts.length != 3 || !parts[0].matches("[a-z0-9_]+")) return null;
        String type = parts[1];
        if ("toggle".equals(type)) {
            if (!"on".equals(parts[2]) && !"off".equals(parts[2])) return null;
            return new Module.Setting(parts[0], Module.SettingType.BOOLEAN, parts[2], new String[] {"on", "off"});
        }
        if (type.startsWith("choice(") && type.endsWith(")")) {
            String[] values = type.substring(7, type.length() - 1).split("\\|", -1);
            for (String value : values) if (!value.matches("[a-z0-9_]+")) return null;
            for (String value : values) if (value.equals(parts[2]))
                return new Module.Setting(parts[0], Module.SettingType.CHOICE, parts[2], values);
            return null;
        }
        if (type.startsWith("number(") && type.endsWith(")")) {
            String[] range = type.substring(7, type.length() - 1).split("\\.\\.", -1);
            if (range.length != 2) return null;
            try {
                long min = Long.parseLong(range[0]), max = Long.parseLong(range[1]);
                long value = Long.parseLong(parts[2]);
                if (min > max || value < min || value > max) return null;
            } catch (NumberFormatException bad) { return null; }
            return new Module.Setting(parts[0], Module.SettingType.BOUNDED_VALUE, parts[2], range);
        }
        return null;
    }

    private static Integer index(String value) {
        if (!value.matches("[1-9][0-9]{0,2}")) return null;
        return Integer.valueOf(value);
    }

    private static String value(Map<String, String> info, String key) {
        String value = info.get(key);
        return value == null ? "" : value;
    }

    private static String[] csv(String value) {
        if (value == null || value.length() == 0) return new String[0];
        List<String> items = new ArrayList<String>();
        for (String item : value.split(",")) if (item.length() > 0) items.add(item);
        return items.toArray(new String[0]);
    }
}
