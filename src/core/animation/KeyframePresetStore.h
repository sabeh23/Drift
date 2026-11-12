#pragma once

#include "core/animation/Keyframe.h"
#include "core/base/Time.h"

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QMutex>
#include <QSize>
#include <QString>

#include <optional>

namespace drift {

// Which effect an animated effect parameter belongs to. Effect params are addressed by their
// position in a stack ("fx.2.strength"), which means nothing on another clip, so a preset records
// the effect itself: its catalog id, which instance of that id it was (a clip can carry two
// blurs), and a snapshot of its static settings so it can be recreated on a clip that lacks it.
struct KeyframePresetEffectRef
{
    QString catalogId;
    int occurrence = 0;     // 0 = the first effect with this catalog id in the stack
    bool audio = false;     // audio effect stack rather than video
    QJsonObject snapshot;   // effectsToJson() entry, keyframes stripped

    bool isValid() const { return !catalogId.isEmpty(); }
};

// One animated property inside a preset. Key times are relative to the preset's start (the
// earliest key across every track), not to any clip.
struct KeyframePresetTrack
{
    // Transform props as the editor names them ("x", "opacity", "rotationY", "text.size"...). For
    // an effect param this is only the param key ("strength", "color.r"), and `effect` says which
    // effect it belongs to.
    QString prop;
    KeyframePresetEffectRef effect;
    KeyframeTrack<double> track;
};

// Where the source clip sat when the preset was saved, at the preset's first key. Applying "fit
// to clip" maps the motion from this layout onto the target clip's, so a preset saved on a
// full-frame clip moves a small sticker by the same proportion rather than the same pixels.
struct KeyframePresetLayout
{
    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;
    double z = 0.0;
    double rotation = 0.0;
    double rotationX = 0.0;
    double rotationY = 0.0;
};

// A reusable bundle of keyframes: saved from one clip, applied to any clip in any project.
struct KeyframePreset
{
    QString id;
    QString label;
    QString clipKind;   // the source clip's kind ("video", "image", "text"...), for display
    QDateTime created;
    TimeUs duration = 0;  // last key time; 0 for a preset whose keys all sit at one instant
    QSize canvas;         // project size it was saved in
    KeyframePresetLayout layout;
    QList<KeyframePresetTrack> tracks;

    int keyCount() const;

    QJsonObject toJson() const;
    static KeyframePreset fromJson(const QJsonObject &object);
};

// The user's keyframe preset library. Persisted per-user (not per-project) as one JSON file in
// the app data folder, like the easing preset library, so a preset saved in one project is there
// in every other.
class KeyframePresetStore
{
public:
    static KeyframePresetStore &instance();

    // By value: the library is read from QML while the GUI thread saves and deletes, so nothing
    // may hand out a pointer into it.
    QList<KeyframePreset> all() const;
    std::optional<KeyframePreset> find(const QString &id) const;

    // Mints the id and timestamp. Returns the id, or an empty string when the label is blank, the
    // preset has no keys, or the save fails.
    QString add(KeyframePreset preset);
    bool rename(const QString &id, const QString &label);
    bool remove(const QString &id);

    // Test seam: drops the in-memory copy so the next read re-reads the file.
    void reload();

    static QString storePath();

private:
    KeyframePresetStore() = default;

    void ensureLoaded() const;  // call with m_mutex held
    bool save() const;          // call with m_mutex held

    mutable QMutex m_mutex;
    mutable QList<KeyframePreset> m_presets;
    mutable bool m_loaded = false;
};

} // namespace drift
