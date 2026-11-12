#include "app/editor/ModManager.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QUrlQuery>

namespace {

const QString kEnabledKey = QStringLiteral("Mods/enabled");

QString defaultRoot()
{
    const QString env = qEnvironmentVariable("DRIFT_MODS_DIR");
    if (!env.isEmpty())
        return QDir::cleanPath(env);
    QString documents = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    if (documents.isEmpty())
        documents = QDir::homePath();
    return QDir(documents).filePath(QStringLiteral("Drift Mods"));
}

QString settingsKey(const QString &modId, const QString &key)
{
    return QStringLiteral("Mods/settings/%1/%2").arg(modId, key);
}

// A hook file has to sit inside its mod's folder: "hooks": {"app": "../../elsewhere.qml"} is
// not a way to load something the user never put there.
bool isInside(const QString &dir, const QString &file)
{
    const QString base = QDir(dir).canonicalPath();
    const QString target = QFileInfo(file).canonicalFilePath();
    return !base.isEmpty() && !target.isEmpty() && target.startsWith(base + QLatin1Char('/'));
}

} // namespace

ModManager::ModManager(QObject *parent, const QString &rootOverride)
    : QObject(parent)
    , m_root(rootOverride.isEmpty() ? defaultRoot() : QDir::cleanPath(rootOverride))
{
    // Editors save in several steps (truncate, write, rename); one reload after they settle.
    m_reloadTimer.setSingleShot(true);
    m_reloadTimer.setInterval(350);
    connect(&m_reloadTimer, &QTimer::timeout, this, &ModManager::reload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_reloadTimer.start(); });
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { m_reloadTimer.start(); });

    QDir().mkpath(m_root);
    scan();
    rewatch();
}

QStringList ModManager::knownHooks()
{
    return {
        QStringLiteral("app"),
        QStringLiteral("panel"),
        QStringLiteral("timelineClip"),
        QStringLiteral("timelineToolbar"),
    };
}

QString ModManager::conventionalFileName(const QString &hook)
{
    if (hook.isEmpty())
        return {};
    return hook.at(0).toUpper() + hook.mid(1) + QStringLiteral(".qml");
}

void ModManager::scan()
{
    m_mods.clear();
    const QDir root(m_root);
    const QStringList folders = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &folder : folders) {
        if (folder.startsWith(QLatin1Char('.')) || folder.startsWith(QLatin1Char('_')))
            continue;
        Mod mod;
        mod.id = folder;
        mod.dir = root.filePath(folder);
        mod.name = folder;

        QJsonObject manifest;
        QFile manifestFile(QDir(mod.dir).filePath(QStringLiteral("mod.json")));
        if (manifestFile.open(QIODevice::ReadOnly)) {
            QJsonParseError parseError;
            const QJsonDocument doc = QJsonDocument::fromJson(manifestFile.readAll(), &parseError);
            if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
                mod.errors.append(QStringLiteral("mod.json: %1").arg(parseError.errorString()));
            } else {
                manifest = doc.object();
            }
        }
        const QString name = manifest.value(QStringLiteral("name")).toString().trimmed();
        if (!name.isEmpty())
            mod.name = name;
        mod.description = manifest.value(QStringLiteral("description")).toString();
        mod.author = manifest.value(QStringLiteral("author")).toString();
        mod.version = manifest.value(QStringLiteral("version")).toString();

        const QJsonObject declared = manifest.value(QStringLiteral("hooks")).toObject();
        for (const QString &hook : knownHooks()) {
            const bool explicitFile = declared.contains(hook);
            const QString relative = explicitFile ? declared.value(hook).toString()
                                                  : conventionalFileName(hook);
            const QString file = QDir(mod.dir).filePath(relative);
            if (!QFileInfo(file).isFile()) {
                if (explicitFile)
                    mod.errors.append(QStringLiteral("%1: %2 not found").arg(hook, relative));
                continue;
            }
            if (!isInside(mod.dir, file)) {
                mod.errors.append(QStringLiteral("%1: %2 is outside the mod's folder").arg(hook, relative));
                continue;
            }
            mod.hooks.insert(hook, QFileInfo(file).absoluteFilePath());
        }
        for (auto it = declared.constBegin(); it != declared.constEnd(); ++it) {
            if (!knownHooks().contains(it.key()))
                mod.errors.append(QStringLiteral("unknown hook \"%1\"").arg(it.key()));
        }

        // A folder with neither a manifest nor a hook file is not a mod (a stray download, a
        // backup): leave it out of the list instead of showing an empty row.
        if (mod.hooks.isEmpty() && manifest.isEmpty() && mod.errors.isEmpty())
            continue;
        m_mods.append(mod);
    }
}

void ModManager::rewatch()
{
    const QStringList watchedFiles = m_watcher.files();
    if (!watchedFiles.isEmpty())
        m_watcher.removePaths(watchedFiles);
    const QStringList watchedDirs = m_watcher.directories();
    if (!watchedDirs.isEmpty())
        m_watcher.removePaths(watchedDirs);

    QStringList paths;
    if (QFileInfo(m_root).isDir())
        paths.append(m_root);
    for (const Mod &mod : m_mods) {
        paths.append(mod.dir);
        // Every QML and JS file, not only the hook files: a hook usually imports its siblings.
        const QDir dir(mod.dir);
        for (const QString &file : dir.entryList({QStringLiteral("*.qml"), QStringLiteral("*.js"),
                                                  QStringLiteral("mod.json")},
                                                 QDir::Files)) {
            paths.append(dir.filePath(file));
        }
    }
    if (!paths.isEmpty())
        m_watcher.addPaths(paths);
}

QStringList ModManager::enabledIds() const
{
    return QSettings().value(kEnabledKey).toStringList();
}

QVariantList ModManager::mods() const
{
    const QStringList enabled = enabledIds();
    QVariantList out;
    for (const Mod &mod : m_mods) {
        QStringList hooks;
        for (const QString &hook : knownHooks()) {
            if (mod.hooks.contains(hook))
                hooks.append(hook);
        }
        out.append(QVariantMap{
            {QStringLiteral("id"), mod.id},
            {QStringLiteral("name"), mod.name},
            {QStringLiteral("description"), mod.description},
            {QStringLiteral("author"), mod.author},
            {QStringLiteral("version"), mod.version},
            {QStringLiteral("enabled"), enabled.contains(mod.id)},
            {QStringLiteral("hooks"), hooks},
            {QStringLiteral("errors"), mod.errors},
        });
    }
    return out;
}

QVariantList ModManager::hookEntries(const QString &hook) const
{
    const QStringList enabled = enabledIds();
    QVariantList out;
    for (const Mod &mod : m_mods) {
        if (!enabled.contains(mod.id) || !mod.hooks.contains(hook))
            continue;
        // The revision in the query makes each reload a new URL, so a loader can never hand back
        // the component it compiled from the file's previous contents.
        QUrl url = QUrl::fromLocalFile(mod.hooks.value(hook));
        QUrlQuery query;
        query.addQueryItem(QStringLiteral("r"), QString::number(m_revision));
        url.setQuery(query);
        out.append(QVariantMap{
            {QStringLiteral("modId"), mod.id},
            {QStringLiteral("name"), mod.name},
            {QStringLiteral("url"), url},
        });
    }
    return out;
}

bool ModManager::hasHook(const QString &hook) const
{
    const QStringList enabled = enabledIds();
    for (const Mod &mod : m_mods) {
        if (enabled.contains(mod.id) && mod.hooks.contains(hook))
            return true;
    }
    return false;
}

bool ModManager::isEnabled(const QString &modId) const
{
    return enabledIds().contains(modId);
}

void ModManager::setEnabled(const QString &modId, bool enabled)
{
    QStringList ids = enabledIds();
    if (ids.contains(modId) == enabled)
        return;
    if (enabled)
        ids.append(modId);
    else
        ids.removeAll(modId);
    QSettings().setValue(kEnabledKey, ids);
    reload();
}

void ModManager::reload()
{
    m_reloadTimer.stop();
    emit aboutToReload();
    emit componentCacheStale();
    QDir().mkpath(m_root);
    scan();
    rewatch();
    ++m_revision;
    emit modsChanged();
}

void ModManager::reportError(const QString &modId, const QString &hook, const QString &message)
{
    for (Mod &mod : m_mods) {
        if (mod.id != modId)
            continue;
        const QString line = QStringLiteral("%1: %2").arg(hook, message);
        if (mod.errors.contains(line))
            return;
        mod.errors.append(line);
        // Not modsChanged: that would reload the hooks, and the broken one would fail again.
        ++m_errorRevision;
        emit errorsChanged();
        return;
    }
}

QVariant ModManager::setting(const QString &modId, const QString &key, const QVariant &fallback) const
{
    return QSettings().value(settingsKey(modId, key), fallback);
}

void ModManager::setSetting(const QString &modId, const QString &key, const QVariant &value)
{
    QSettings().setValue(settingsKey(modId, key), value);
}

void ModManager::post(const QString &modId, const QString &topic, const QVariant &payload)
{
    emit message(modId, topic, payload);
}
