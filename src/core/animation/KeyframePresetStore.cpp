#include "core/animation/KeyframePresetStore.h"

#include "core/effects/Effect.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMutexLocker>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>

namespace drift {

namespace {

const QString kIdPrefix = QStringLiteral("user:");
constexpr int kLibraryVersion = 1;

QString mintId()
{
    return kIdPrefix + QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QJsonObject layoutToJson(const KeyframePresetLayout &layout)
{
    return QJsonObject{
        {QStringLiteral("x"), layout.x},
        {QStringLiteral("y"), layout.y},
        {QStringLiteral("width"), layout.width},
        {QStringLiteral("height"), layout.height},
        {QStringLiteral("z"), layout.z},
        {QStringLiteral("rotation"), layout.rotation},
        {QStringLiteral("rotationX"), layout.rotationX},
        {QStringLiteral("rotationY"), layout.rotationY},
    };
}

KeyframePresetLayout layoutFromJson(const QJsonObject &object)
{
    KeyframePresetLayout layout;
    layout.x = object.value(QStringLiteral("x")).toDouble();
    layout.y = object.value(QStringLiteral("y")).toDouble();
    layout.width = object.value(QStringLiteral("width")).toDouble();
    layout.height = object.value(QStringLiteral("height")).toDouble();
    layout.z = object.value(QStringLiteral("z")).toDouble();
    layout.rotation = object.value(QStringLiteral("rotation")).toDouble();
    layout.rotationX = object.value(QStringLiteral("rotationX")).toDouble();
    layout.rotationY = object.value(QStringLiteral("rotationY")).toDouble();
    return layout;
}

} // namespace

int KeyframePreset::keyCount() const
{
    int count = 0;
    for (const KeyframePresetTrack &t : tracks)
        count += static_cast<int>(t.track.keyframes().size());
    return count;
}

QJsonObject KeyframePreset::toJson() const
{
    QJsonArray trackArray;
    for (const KeyframePresetTrack &t : tracks) {
        QJsonObject entry{
            {QStringLiteral("prop"), t.prop},
            {QStringLiteral("keys"), keyframesToJson(t.track)},
        };
        if (t.effect.isValid()) {
            entry.insert(QStringLiteral("effect"),
                         QJsonObject{
                             {QStringLiteral("catalogId"), t.effect.catalogId},
                             {QStringLiteral("occurrence"), t.effect.occurrence},
                             {QStringLiteral("audio"), t.effect.audio},
                             {QStringLiteral("snapshot"), t.effect.snapshot},
                         });
        }
        trackArray.append(entry);
    }

    return QJsonObject{
        {QStringLiteral("id"), id},
        {QStringLiteral("label"), label},
        {QStringLiteral("clipKind"), clipKind},
        {QStringLiteral("created"), created.toString(Qt::ISODate)},
        {QStringLiteral("durationUs"), static_cast<double>(duration)},
        {QStringLiteral("canvas"),
         QJsonObject{{QStringLiteral("width"), canvas.width()},
                     {QStringLiteral("height"), canvas.height()}}},
        {QStringLiteral("layout"), layoutToJson(layout)},
        {QStringLiteral("tracks"), trackArray},
    };
}

KeyframePreset KeyframePreset::fromJson(const QJsonObject &object)
{
    KeyframePreset preset;
    preset.id = object.value(QStringLiteral("id")).toString();
    preset.label = object.value(QStringLiteral("label")).toString();
    preset.clipKind = object.value(QStringLiteral("clipKind")).toString();
    preset.created =
        QDateTime::fromString(object.value(QStringLiteral("created")).toString(), Qt::ISODate);
    preset.duration = static_cast<TimeUs>(object.value(QStringLiteral("durationUs")).toDouble());
    const QJsonObject canvas = object.value(QStringLiteral("canvas")).toObject();
    preset.canvas = QSize(canvas.value(QStringLiteral("width")).toInt(),
                          canvas.value(QStringLiteral("height")).toInt());
    preset.layout = layoutFromJson(object.value(QStringLiteral("layout")).toObject());

    for (const QJsonValue &value : object.value(QStringLiteral("tracks")).toArray()) {
        const QJsonObject entry = value.toObject();
        KeyframePresetTrack t;
        t.prop = entry.value(QStringLiteral("prop")).toString();
        t.track = keyframesFromJson(entry.value(QStringLiteral("keys")).toObject());
        const QJsonObject effect = entry.value(QStringLiteral("effect")).toObject();
        if (!effect.isEmpty()) {
            t.effect.catalogId = effect.value(QStringLiteral("catalogId")).toString();
            t.effect.occurrence = qMax(0, effect.value(QStringLiteral("occurrence")).toInt());
            t.effect.audio = effect.value(QStringLiteral("audio")).toBool();
            t.effect.snapshot = effect.value(QStringLiteral("snapshot")).toObject();
        }
        if (t.prop.isEmpty() || t.track.isEmpty())
            continue;
        preset.tracks.append(t);
    }
    return preset;
}

KeyframePresetStore &KeyframePresetStore::instance()
{
    static KeyframePresetStore store;
    return store;
}

QString KeyframePresetStore::storePath()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty())
        return {};
    return QDir(base).filePath(QStringLiteral("keyframe-presets.json"));
}

void KeyframePresetStore::ensureLoaded() const
{
    if (m_loaded)
        return;
    m_loaded = true;
    m_presets.clear();

    const QString path = storePath();
    if (path.isEmpty())
        return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return; // no library yet

    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    for (const QJsonValue &value : root.value(QStringLiteral("presets")).toArray()) {
        KeyframePreset preset = KeyframePreset::fromJson(value.toObject());
        if (!preset.id.startsWith(kIdPrefix) || preset.label.isEmpty() || preset.tracks.isEmpty())
            continue;
        m_presets.append(preset);
    }
}

bool KeyframePresetStore::save() const
{
    const QString path = storePath();
    if (path.isEmpty())
        return false;

    QDir().mkpath(QFileInfo(path).absolutePath());

    QJsonArray presets;
    for (const KeyframePreset &preset : m_presets)
        presets.append(preset.toJson());

    const QJsonObject root{
        {QStringLiteral("version"), kLibraryVersion},
        {QStringLiteral("presets"), presets},
    };

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    return file.commit();
}

QList<KeyframePreset> KeyframePresetStore::all() const
{
    QMutexLocker locker(&m_mutex);
    ensureLoaded();
    return m_presets;
}

std::optional<KeyframePreset> KeyframePresetStore::find(const QString &id) const
{
    QMutexLocker locker(&m_mutex);
    ensureLoaded();
    for (const KeyframePreset &preset : m_presets) {
        if (preset.id == id)
            return preset;
    }
    return std::nullopt;
}

QString KeyframePresetStore::add(KeyframePreset preset)
{
    preset.label = preset.label.trimmed();
    if (preset.label.isEmpty() || preset.tracks.isEmpty())
        return {};

    QMutexLocker locker(&m_mutex);
    ensureLoaded();

    preset.id = mintId();
    preset.created = QDateTime::currentDateTimeUtc();
    m_presets.prepend(preset);
    if (!save()) {
        m_presets.removeFirst();
        return {};
    }
    return preset.id;
}

bool KeyframePresetStore::rename(const QString &id, const QString &label)
{
    const QString trimmed = label.trimmed();
    if (trimmed.isEmpty())
        return false;

    QMutexLocker locker(&m_mutex);
    ensureLoaded();
    for (KeyframePreset &preset : m_presets) {
        if (preset.id != id)
            continue;
        const QString previous = preset.label;
        preset.label = trimmed;
        if (!save()) {
            preset.label = previous;
            return false;
        }
        return true;
    }
    return false;
}

bool KeyframePresetStore::remove(const QString &id)
{
    QMutexLocker locker(&m_mutex);
    ensureLoaded();
    for (int i = 0; i < m_presets.size(); ++i) {
        if (m_presets.at(i).id != id)
            continue;
        const KeyframePreset removed = m_presets.takeAt(i);
        if (!save()) {
            m_presets.insert(i, removed);
            return false;
        }
        return true;
    }
    return false;
}

void KeyframePresetStore::reload()
{
    QMutexLocker locker(&m_mutex);
    m_loaded = false;
    m_presets.clear();
}

} // namespace drift
