// Keyframe presets: a clip's animation saved to the user's library and applied to any other clip,
// in this project or another. The library itself is core/animation/KeyframePresetStore; this file
// is the part that knows how a clip's properties are addressed and where their keys live.

#include "app/editor/appcontroller/AppControllerInternal.h"
#include "core/animation/KeyframePresetStore.h"
#include "core/effects/Effect.h"
#include "core/effects/Mask.h"
#include "engine/packages/audio/AudioEffectCatalog.h"
#include "engine/packages/effects/EffectCatalog.h"

#include <QHash>
#include <QSet>

#include <functional>
#include <limits>

using namespace drift::appdetail;
using namespace drift::appcontroller_detail;

namespace {

// Finding a key we just wrote. writeKeyframeValue snaps onto a key within half a millisecond, so
// the key it wrote is never further than that from where we asked.
constexpr drift::TimeUs kFindWrittenKeyUs = 1000;

// How a property's values move when a preset is fitted onto a different clip.
enum class FitRule {
    None,       // used as saved (opacity, effect params, text size...)
    OffsetX,    // position: start from the target's, offsets scaled by the width ratio
    OffsetY,
    ScaleX,     // a size or a size-relative offset: scaled by the width ratio
    ScaleY,
    OffsetRaw,  // depth and rotations: start from the target's, offsets as saved
};

FitRule fitRuleFor(const QString &prop)
{
    if (prop == QLatin1String("x"))
        return FitRule::OffsetX;
    if (prop == QLatin1String("y"))
        return FitRule::OffsetY;
    if (prop == QLatin1String("width") || prop == QLatin1String("anchorX"))
        return FitRule::ScaleX;
    if (prop == QLatin1String("height") || prop == QLatin1String("anchorY"))
        return FitRule::ScaleY;
    if (prop == QLatin1String("z") || prop == QLatin1String("rotation")
        || prop == QLatin1String("rotationX") || prop == QLatin1String("rotationY"))
        return FitRule::OffsetRaw;
    return FitRule::None;
}

QString effectKey(const drift::KeyframePresetEffectRef &ref)
{
    return QStringLiteral("%1|%2|%3").arg(ref.audio ? 1 : 0).arg(ref.occurrence).arg(ref.catalogId);
}

QString transformLabel(const QString &prop)
{
    static const QHash<QString, const char *> labels{
        {QStringLiteral("x"), QT_TRANSLATE_NOOP("AppController", "Position X")},
        {QStringLiteral("y"), QT_TRANSLATE_NOOP("AppController", "Position Y")},
        {QStringLiteral("width"), QT_TRANSLATE_NOOP("AppController", "Width")},
        {QStringLiteral("height"), QT_TRANSLATE_NOOP("AppController", "Height")},
        {QStringLiteral("rotation"), QT_TRANSLATE_NOOP("AppController", "Rotation")},
        {QStringLiteral("rotationX"), QT_TRANSLATE_NOOP("AppController", "Rotation X")},
        {QStringLiteral("rotationY"), QT_TRANSLATE_NOOP("AppController", "Rotation Y")},
        {QStringLiteral("z"), QT_TRANSLATE_NOOP("AppController", "Depth")},
        {QStringLiteral("perspective"), QT_TRANSLATE_NOOP("AppController", "Perspective")},
        {QStringLiteral("anchorX"), QT_TRANSLATE_NOOP("AppController", "Anchor X")},
        {QStringLiteral("anchorY"), QT_TRANSLATE_NOOP("AppController", "Anchor Y")},
        {QStringLiteral("anchorZ"), QT_TRANSLATE_NOOP("AppController", "Anchor Z")},
        {QStringLiteral("opacity"), QT_TRANSLATE_NOOP("AppController", "Opacity")},
        {QStringLiteral("volume"), QT_TRANSLATE_NOOP("AppController", "Volume")},
    };
    const auto it = labels.constFind(prop);
    return it == labels.constEnd() ? QString() : AppController::tr(it.value());
}

// "Dither · Levels" for an effect param; the colour channel suffix (".r") is kept readable.
QString effectParamLabel(const drift::KeyframePresetEffectRef &ref, const QString &paramKey)
{
    QString effectName;
    QList<drift::EffectParamSpec> specs;
    if (ref.audio) {
        if (const AudioEffectEntry *def = audioEffectDefForId(ref.catalogId)) {
            effectName = def->displayName;
            specs = def->parameters;
        }
    } else if (const EffectPresetEntry *def = effectDefForId(ref.catalogId)) {
        effectName = def->meta.displayName;
        specs = def->meta.parameters;
    }
    if (effectName.isEmpty())
        effectName = ref.catalogId;

    QString base = paramKey;
    QString channel;
    const int dot = paramKey.lastIndexOf(QLatin1Char('.'));
    if (dot > 0) {
        base = paramKey.left(dot);
        channel = paramKey.mid(dot + 1).toUpper();
    }
    QString paramName = base;
    for (const drift::EffectParamSpec &spec : specs) {
        if (spec.key == base) {
            if (!spec.label.isEmpty())
                paramName = spec.label;
            break;
        }
    }
    if (!channel.isEmpty())
        paramName += QStringLiteral(" ") + channel;
    return effectName + QStringLiteral(" · ") + paramName;
}

} // namespace

QVariantList AppController::keyframePresets() const
{
    QVariantList out;
    for (const drift::KeyframePreset &preset : drift::KeyframePresetStore::instance().all()) {
        QStringList properties;
        for (const drift::KeyframePresetTrack &t : preset.tracks) {
            QString label;
            if (t.effect.isValid())
                label = effectParamLabel(t.effect, t.prop);
            else if (t.prop.startsWith(QLatin1String("mask.")))
                label = tr("Mask · %1").arg(t.prop.mid(5));
            else
                label = transformLabel(t.prop);
            if (label.isEmpty())
                label = keyframePropertyLabel(-1, -1, t.prop);
            properties.append(label.isEmpty() ? t.prop : label);
        }
        out.append(QVariantMap{
            {QStringLiteral("id"), preset.id},
            {QStringLiteral("label"), preset.label},
            {QStringLiteral("clipKind"), preset.clipKind},
            {QStringLiteral("duration"), drift::usToSeconds(preset.duration)},
            {QStringLiteral("keyCount"), preset.keyCount()},
            {QStringLiteral("properties"), properties},
        });
    }
    return out;
}

QVariantList AppController::keyframePresetCandidates(int trackIndex, int clipIndex) const
{
    QVariantList out;
    if (!isValidClipIndex(trackIndex, clipIndex))
        return out;
    for (const QString &prop : clipAnimatedProperties(trackIndex, clipIndex)) {
        int hostTrack = trackIndex;
        int hostClip = clipIndex;
        redirectToKeyframeHost(&hostTrack, &hostClip, prop);
        const drift::Clip &host = m_project.tracks().at(hostTrack).clips.at(hostClip);
        const drift::KeyframeTrack<double> *track = keyframeTrackForProp(host, prop);
        if (!track || track->isEmpty())
            continue;

        QString label = transformLabel(prop);
        int effectIndex = -1;
        QString paramKey;
        const bool audio = parseAudioEffectProp(prop, &effectIndex, &paramKey);
        if (audio || parseEffectProp(prop, &effectIndex, &paramKey)) {
            const QList<drift::Effect> &stack = audio ? host.audioEffects : host.effects;
            if (effectIndex >= 0 && effectIndex < stack.size()) {
                drift::KeyframePresetEffectRef ref;
                ref.catalogId = stack.at(effectIndex).catalogId;
                ref.audio = audio;
                label = effectParamLabel(ref, paramKey);
            }
        } else if (prop.startsWith(QLatin1String("mask."))) {
            label = tr("Mask · %1").arg(prop.mid(5));
        }
        if (label.isEmpty())
            label = keyframePropertyLabel(trackIndex, clipIndex, prop);
        out.append(QVariantMap{
            {QStringLiteral("prop"), prop},
            {QStringLiteral("label"), label.isEmpty() ? prop : label},
            {QStringLiteral("keyCount"), static_cast<int>(track->keyframes().size())},
        });
    }
    return out;
}

QString AppController::saveKeyframePreset(int trackIndex, int clipIndex, const QString &label,
                                          const QStringList &props)
{
    if (!isValidClipIndex(trackIndex, clipIndex))
        return {};
    if (label.trimmed().isEmpty()) {
        setLastMessage(tr("Give the keyframe preset a name"), QStringLiteral("warning"));
        return {};
    }

    const drift::Clip &clip = m_project.tracks().at(trackIndex).clips.at(clipIndex);
    const QStringList animated = clipAnimatedProperties(trackIndex, clipIndex);

    drift::KeyframePreset preset;
    preset.label = label.trimmed();
    preset.clipKind = drift::clipTypeToString(clip.type);
    preset.canvas = QSize(m_project.width(), m_project.height());

    drift::TimeUs earliest = std::numeric_limits<drift::TimeUs>::max();
    drift::TimeUs latest = std::numeric_limits<drift::TimeUs>::min();

    for (const QString &prop : animated) {
        if (!props.isEmpty() && !props.contains(prop))
            continue;

        int hostTrack = trackIndex;
        int hostClip = clipIndex;
        redirectToKeyframeHost(&hostTrack, &hostClip, prop);
        const drift::Clip &host = m_project.tracks().at(hostTrack).clips.at(hostClip);
        const drift::KeyframeTrack<double> *source = keyframeTrackForProp(host, prop);
        if (!source || source->isEmpty())
            continue;

        drift::KeyframePresetTrack entry;
        int effectIndex = -1;
        QString paramKey;
        const bool audio = parseAudioEffectProp(prop, &effectIndex, &paramKey);
        if (audio || parseEffectProp(prop, &effectIndex, &paramKey)) {
            const QList<drift::Effect> &stack = audio ? host.audioEffects : host.effects;
            if (effectIndex < 0 || effectIndex >= stack.size())
                continue;
            const drift::Effect &effect = stack.at(effectIndex);
            if (effect.catalogId.isEmpty())
                continue;
            entry.prop = paramKey;
            entry.effect.catalogId = effect.catalogId;
            entry.effect.audio = audio;
            for (int i = 0; i < effectIndex; ++i) {
                if (stack.at(i).catalogId == effect.catalogId)
                    ++entry.effect.occurrence;
            }
            drift::Effect snapshot = effect;
            snapshot.paramKeyframes.clear();
            entry.effect.snapshot = drift::effectsToJson({snapshot}).first().toObject();
        } else {
            entry.prop = prop;
        }

        // Keys are relative to the clip that holds them, and an effect's or mask's holder is an
        // adjustment that need not start where this clip does. Rebase everything onto this clip.
        const drift::TimeUs offset = host.timelineStart - clip.timelineStart;
        for (auto it = source->keyframes().constBegin(); it != source->keyframes().constEnd(); ++it) {
            const drift::TimeUs at = it.key() + offset;
            entry.track.setKeyframe(at, it.value());
            earliest = qMin(earliest, at);
            latest = qMax(latest, at);
        }
        entry.track.setEnabled(source->enabled());
        preset.tracks.append(entry);
    }

    if (preset.tracks.isEmpty()) {
        setLastMessage(tr("This clip has no keyframes to save"), QStringLiteral("warning"));
        return {};
    }

    // The preset starts at its first key: applying it then puts that key at the playhead.
    for (drift::KeyframePresetTrack &entry : preset.tracks)
        entry.track.shiftBy(-earliest);
    preset.duration = latest - earliest;

    const drift::TimeUs at = qMax<drift::TimeUs>(0, earliest);
    preset.layout.x = clipTransformValue(clip.transformX, at, 0.0);
    preset.layout.y = clipTransformValue(clip.transformY, at, 0.0);
    preset.layout.width = clipTransformValue(clip.transformW, at, m_project.width());
    preset.layout.height = clipTransformValue(clip.transformH, at, m_project.height());
    preset.layout.z = clipTransformValue(clip.positionZ, at, 0.0);
    preset.layout.rotation = clipTransformValue(clip.rotation, at, 0.0);
    preset.layout.rotationX = clipTransformValue(clip.rotationX, at, 0.0);
    preset.layout.rotationY = clipTransformValue(clip.rotationY, at, 0.0);

    const QString id = drift::KeyframePresetStore::instance().add(preset);
    if (id.isEmpty()) {
        setLastMessage(tr("Could not save the keyframe preset"), QStringLiteral("error"));
        return {};
    }
    emit keyframePresetsChanged();
    setLastMessage(tr("Saved keyframe preset “%1”").arg(preset.label));
    return id;
}

bool AppController::applyKeyframePreset(int trackIndex, int clipIndex, const QString &presetId,
                                        bool fitToClip, double atSeconds)
{
    if (!isValidClipIndex(trackIndex, clipIndex))
        return false;
    const std::optional<drift::KeyframePreset> found =
        drift::KeyframePresetStore::instance().find(presetId);
    if (!found) {
        setLastMessage(tr("That keyframe preset no longer exists"), QStringLiteral("warning"));
        return false;
    }
    const drift::KeyframePreset &preset = *found;

    // Adding an effect host inserts a track, so the target is followed by id rather than index.
    m_project.ensureTrackIds();
    const QString targetId = m_project.tracks().at(trackIndex).clips.at(clipIndex).id;
    const auto locateTarget = [&](int *t, int *c) {
        return findClipById(m_project, targetId, t, c);
    };

    const drift::Project before = m_project;
    QStringList skipped;

    // 1. Make sure every effect the preset animates exists on the target, adding the missing ones
    //    with the settings they had when the preset was saved. Structural work first, so the
    //    indices the keys are written through below are final.
    QHash<QString, int> effectIndexFor;
    for (const drift::KeyframePresetTrack &entry : preset.tracks) {
        if (!entry.effect.isValid())
            continue;
        const QString key = effectKey(entry.effect);
        if (effectIndexFor.contains(key) || skipped.contains(key))
            continue;

        int t = -1;
        int c = -1;
        if (!locateTarget(&t, &c))
            return false;
        const drift::Clip &target = m_project.tracks().at(t).clips.at(c);
        const bool known = entry.effect.audio ? audioEffectDefForId(entry.effect.catalogId) != nullptr
                                              : effectDefForId(entry.effect.catalogId) != nullptr;
        const bool fits = entry.effect.audio
                              ? (target.type == drift::ClipType::Audio
                                 || target.type == drift::ClipType::Video)
                              : effectFitsTrack(t, entry.effect.catalogId);
        if (!known || !fits) {
            skipped.append(key);
            continue;
        }

        if (!redirectToEffectHost(&t, &c,
                                  entry.effect.audio ? drift::AdjustmentKind::AudioEffects
                                                     : drift::AdjustmentKind::VideoEffects,
                                  /*create=*/true)) {
            skipped.append(key);
            continue;
        }
        drift::Clip &host = m_project.tracks()[t].clips[c];
        QList<drift::Effect> &stack = entry.effect.audio ? host.audioEffects : host.effects;

        int seen = 0;
        int index = -1;
        for (int i = 0; i < stack.size(); ++i) {
            if (stack.at(i).catalogId != entry.effect.catalogId)
                continue;
            if (seen == entry.effect.occurrence) {
                index = i;
                break;
            }
            ++seen;
        }
        if (index < 0) {
            QList<drift::Effect> restored = drift::effectsFromJson(QJsonArray{entry.effect.snapshot});
            if (restored.isEmpty() || restored.first().catalogId != entry.effect.catalogId) {
                skipped.append(key);
                continue;
            }
            drift::Effect fresh = restored.first();
            fresh.paramKeyframes.clear();
            while (seen <= entry.effect.occurrence) {
                stack.append(fresh);
                ++seen;
            }
            index = stack.size() - 1;
        }
        effectIndexFor.insert(key, index);
    }

    int targetTrack = -1;
    int targetClip = -1;
    if (!locateTarget(&targetTrack, &targetClip))
        return false;
    const drift::Clip targetSnapshot = m_project.tracks().at(targetTrack).clips.at(targetClip);

    // 2. Where the preset starts on this clip: at the playhead, or the clip's start when the
    //    playhead is somewhere else.
    drift::TimeUs startRel = drift::secondsToUs(atSeconds) - targetSnapshot.timelineStart;
    if (startRel < 0 || startRel > targetSnapshot.timelineDuration)
        startRel = 0;

    // 3. How values map onto this clip.
    const double canvasX = preset.canvas.width() > 0
                               ? double(m_project.width()) / preset.canvas.width()
                               : 1.0;
    const double canvasY = preset.canvas.height() > 0
                               ? double(m_project.height()) / preset.canvas.height()
                               : 1.0;
    const double baseX = clipTransformValue(targetSnapshot.transformX, startRel, 0.0);
    const double baseY = clipTransformValue(targetSnapshot.transformY, startRel, 0.0);
    const double baseW = clipTransformValue(targetSnapshot.transformW, startRel, m_project.width());
    const double baseH = clipTransformValue(targetSnapshot.transformH, startRel, m_project.height());
    const double ratioX = fitToClip
                              ? (preset.layout.width > 1e-6 ? baseW / preset.layout.width : 1.0)
                              : canvasX;
    const double ratioY = fitToClip
                              ? (preset.layout.height > 1e-6 ? baseH / preset.layout.height : 1.0)
                              : canvasY;
    const auto baseRaw = [&](const QString &prop) {
        if (prop == QLatin1String("z"))
            return qMakePair(clipTransformValue(targetSnapshot.positionZ, startRel, 0.0), preset.layout.z);
        if (prop == QLatin1String("rotation"))
            return qMakePair(clipTransformValue(targetSnapshot.rotation, startRel, 0.0), preset.layout.rotation);
        if (prop == QLatin1String("rotationX"))
            return qMakePair(clipTransformValue(targetSnapshot.rotationX, startRel, 0.0), preset.layout.rotationX);
        return qMakePair(clipTransformValue(targetSnapshot.rotationY, startRel, 0.0), preset.layout.rotationY);
    };

    // 4. Write the keys.
    int written = 0;
    int clipped = 0;
    for (const drift::KeyframePresetTrack &entry : preset.tracks) {
        QString prop = entry.prop;
        if (entry.effect.isValid()) {
            const QString key = effectKey(entry.effect);
            if (!effectIndexFor.contains(key))
                continue;
            prop = QStringLiteral("%1.%2.%3")
                       .arg(entry.effect.audio ? QStringLiteral("afx") : QStringLiteral("fx"))
                       .arg(effectIndexFor.value(key))
                       .arg(entry.prop);
        }

        int hostTrack = targetTrack;
        int hostClip = targetClip;
        if (prop.startsWith(QLatin1String("mask."))) {
            // A mask lives on its own adjustment. Without one there is nothing for these keys to
            // move, and writing them onto the clip itself would hide them where nothing reads.
            const drift::ClipRef maskHost =
                effectHostRef(targetTrack, targetClip, drift::AdjustmentKind::Mask, /*create=*/false);
            if (maskHost.trackIndex < 0) {
                skipped.append(prop);
                continue;
            }
        }
        redirectToKeyframeHost(&hostTrack, &hostClip, prop);
        drift::Clip &host = m_project.tracks()[hostTrack].clips[hostClip];
        const drift::TimeUs toHost = targetSnapshot.timelineStart - host.timelineStart;

        double scale = 1.0;
        std::function<double(double)> map = [](double v) { return v; };
        switch (fitToClip ? fitRuleFor(prop) : FitRule::None) {
        case FitRule::OffsetX:
            scale = ratioX;
            map = [&, ratioX, baseX](double v) { return baseX + (v - preset.layout.x) * ratioX; };
            break;
        case FitRule::OffsetY:
            scale = ratioY;
            map = [&, ratioY, baseY](double v) { return baseY + (v - preset.layout.y) * ratioY; };
            break;
        case FitRule::ScaleX:
            scale = ratioX;
            map = [ratioX](double v) { return v * ratioX; };
            break;
        case FitRule::ScaleY:
            scale = ratioY;
            map = [ratioY](double v) { return v * ratioY; };
            break;
        case FitRule::OffsetRaw: {
            const auto bases = baseRaw(prop);
            map = [bases](double v) { return bases.first + (v - bases.second); };
            break;
        }
        case FitRule::None:
            if (!fitToClip) {
                // Exact values, but a different canvas size still has to scale pixel layout.
                if (prop == QLatin1String("x") || prop == QLatin1String("width")
                    || prop == QLatin1String("anchorX")) {
                    scale = canvasX;
                    map = [canvasX](double v) { return v * canvasX; };
                } else if (prop == QLatin1String("y") || prop == QLatin1String("height")
                           || prop == QLatin1String("anchorY")) {
                    scale = canvasY;
                    map = [canvasY](double v) { return v * canvasY; };
                }
            }
            break;
        }

        // Replace what is already there across the preset's span, so the result is the preset's
        // motion and not a blend of it with whatever keys happened to sit in between.
        if (drift::KeyframeTrack<double> *existing = keyframeTrackForProp(host, prop, false)) {
            const drift::TimeUs from = startRel + toHost;
            const drift::TimeUs to = from + preset.duration;
            QList<drift::TimeUs> doomed;
            for (auto it = existing->keyframes().constBegin(); it != existing->keyframes().constEnd(); ++it) {
                if (it.key() >= from && it.key() <= to)
                    doomed.append(it.key());
            }
            for (drift::TimeUs at : doomed)
                existing->removeKeyframe(at);
        }

        bool wroteAny = false;
        for (auto it = entry.track.keyframes().constBegin(); it != entry.track.keyframes().constEnd(); ++it) {
            const drift::TimeUs targetRel = startRel + it.key();
            if (targetRel > targetSnapshot.timelineDuration) {
                ++clipped;
                continue;
            }
            const drift::TimeUs hostRel = targetRel + toHost;
            if (hostRel < 0)
                continue;
            const drift::Keyframe<double> &source = it.value();
            if (!writeClipPropValue(host, prop, hostRel, map(source.value), /*autoKey=*/true,
                                    /*force=*/true)) {
                break;
            }
            wroteAny = true;
            ++written;
            // The write only sets the value; the curve's shape comes from the saved tangents.
            drift::KeyframeTrack<double> *track = keyframeTrackForProp(host, prop, false);
            const drift::TimeUs at = track ? track->nearestKeyframe(hostRel, kFindWrittenKeyUs) : -1;
            if (drift::Keyframe<double> *key = at >= 0 ? track->keyframeRef(at) : nullptr) {
                key->inDx = source.inDx;
                key->outDx = source.outDx;
                key->inDy = source.inDy * scale;
                key->outDy = source.outDy * scale;
                key->corner = source.corner;
                key->hold = source.hold;
                key->fn = source.fn;
                key->fnAmplitude = source.fnAmplitude;
                key->fnPeriod = source.fnPeriod;
            }
        }
        if (!wroteAny)
            skipped.append(prop);
    }

    if (written == 0) {
        m_project = before;
        setLastMessage(tr("Nothing in “%1” applies to this clip").arg(preset.label),
                       QStringLiteral("warning"));
        return false;
    }

    pushProjectEdit(before, tr("Apply keyframe preset"));
    QString message = tr("Applied “%1”").arg(preset.label);
    if (clipped > 0)
        message += tr(" — %n key(s) past the clip's end left out", nullptr, clipped);
    if (!skipped.isEmpty())
        message += tr(" — some properties don't apply to this clip");
    finishEdit(message);
    return true;
}

bool AppController::renameKeyframePreset(const QString &id, const QString &label)
{
    if (!drift::KeyframePresetStore::instance().rename(id, label))
        return false;
    emit keyframePresetsChanged();
    return true;
}

bool AppController::deleteKeyframePreset(const QString &id)
{
    if (!drift::KeyframePresetStore::instance().remove(id))
        return false;
    emit keyframePresetsChanged();
    return true;
}
