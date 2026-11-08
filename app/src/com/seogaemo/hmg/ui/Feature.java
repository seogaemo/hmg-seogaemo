package com.seogaemo.hmg.ui;

import android.content.Context;
import com.seogaemo.hmg.module.InstalledModule;
import com.seogaemo.hmg.module.Module;

/** One Features card: a built-in module or an installed package, with display strings resolved. */
public final class Feature {
    public final String id;
    public final String name;
    public final String description;
    public final String icon;
    public final Module builtIn;
    public final InstalledModule installed;

    private Feature(String id, String name, String description, String icon, Module builtIn,
            InstalledModule installed) {
        this.id = id;
        this.name = name;
        this.description = description;
        this.icon = icon;
        this.builtIn = builtIn;
        this.installed = installed;
    }

    public static Feature of(Context context, Module module) {
        return new Feature(module.id(), context.getString(module.nameResId()),
                context.getString(module.descriptionResId()), module.icon(), module, null);
    }

    public static Feature of(InstalledModule module) {
        return new Feature(module.id, module.name(), module.summary(), module.icon, null, module);
    }

    public boolean rebootRestore() {
        return builtIn != null ? builtIn.rebootRestore() : installed.rebootRestore;
    }

    public boolean needsHeadUnitRestart() {
        return builtIn != null ? builtIn.restartRequirement() == Module.RestartRequirement.HEAD_UNIT
                : "head_unit".equals(installed.restart);
    }

    /** A one-shot module: its card shows one action button instead of the on/off state. */
    public boolean isAction() { return installed != null && installed.action && installed.actionName != null; }

    public boolean removable() { return installed != null; }
}
