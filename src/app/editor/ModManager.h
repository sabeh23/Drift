#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

// User mods: folders of QML that Drift loads into fixed hook points of its own interface, so a
// feature that only needs what the interface already exposes (EditorState, Workspaces, Theme...)
// can be added, changed or removed without rebuilding the app.
//
// A mod is a folder under the mods directory:
//
//     Drift Mods/
//       keyframe-diamonds/
//         mod.json            optional: { "name", "description", "author", "version",
//                                         "hooks": { "<hook>": "<file.qml>" } }
//         TimelineClip.qml    without a "hooks" entry, a hook loads the file named after it
//
// Hooks (see knownHooks()): each one instantiates the mod's file with a `host` property set to
// the item it decorates.
//
//   app              once, over the whole editor window. host: the ApplicationWindow
//   panel            over every panel slot of the workspace. host: the WorkspaceSlot
//                    (host.entries lists the panel types it shows, host.node its layout node)
//   timelineClip     over every clip on the timeline. host: the TimelineClipItem
//                    (host.trackIndex, host.clipIndex, host.clipData, host.panel.pxPerSecond)
//   timelineToolbar  appended to the timeline toolbar's button row. host: the toolbar
//
// Mods are ordinary QML and run with Drift's own permissions, which is why a new mod stays off
// until it is switched on in Settings > Mods. The folder is watched: saving a file reloads the
// mods in place.
class ModManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QVariantList mods READ mods NOTIFY modsChanged)
    // Bumped on every reload. Bind to it to re-read hookEntries().
    Q_PROPERTY(int revision READ revision NOTIFY modsChanged)
    // Bumped when a hook reports a load error; the mods list re-reads on it without reloading.
    Q_PROPERTY(int errorRevision READ errorRevision NOTIFY errorsChanged)
    Q_PROPERTY(QString folder READ folder CONSTANT)
    Q_PROPERTY(QUrl folderUrl READ folderUrl CONSTANT)

public:
    // `rootOverride` replaces the mods directory (tests). Otherwise DRIFT_MODS_DIR, or
    // "<Documents>/Drift Mods".
    explicit ModManager(QObject *parent = nullptr, const QString &rootOverride = {});

    static QStringList knownHooks();
    // "timelineClip" -> "TimelineClip.qml"
    static QString conventionalFileName(const QString &hook);

    // [{id, name, description, author, version, enabled, hooks: [names], errors: [text]}]
    QVariantList mods() const;
    int revision() const { return m_revision; }
    int errorRevision() const { return m_errorRevision; }
    QString folder() const { return m_root; }
    QUrl folderUrl() const { return QUrl::fromLocalFile(m_root); }

    // The enabled mods that implement `hook`, in folder-name order: [{modId, name, url}].
    Q_INVOKABLE QVariantList hookEntries(const QString &hook) const;
    Q_INVOKABLE bool hasHook(const QString &hook) const;

    Q_INVOKABLE bool isEnabled(const QString &modId) const;
    Q_INVOKABLE void setEnabled(const QString &modId, bool enabled);

    // Creates the mods folder if needed, rescans it and reloads every hook.
    Q_INVOKABLE void reload();

    // A hook file that failed to load. Shown on the mod's row in Settings until the next reload.
    Q_INVOKABLE void reportError(const QString &modId, const QString &hook, const QString &message);

    // Small per-mod key/value storage, kept with Drift's own settings.
    Q_INVOKABLE QVariant setting(const QString &modId, const QString &key,
                                 const QVariant &fallback = {}) const;
    Q_INVOKABLE void setSetting(const QString &modId, const QString &key, const QVariant &value);

    // A mod's instances are separate objects (one per clip, one per panel...). post() reaches all
    // of them: each connects to message() and filters on its own modId.
    Q_INVOKABLE void post(const QString &modId, const QString &topic, const QVariant &payload = {});

signals:
    // Hook hosts drop their loaded items here, before the files are read again.
    void aboutToReload();
    // The QML engine's component cache has to go, or an edited file would load from memory.
    void componentCacheStale();
    void modsChanged();
    void errorsChanged();
    void message(const QString &modId, const QString &topic, const QVariant &payload);

private:
    struct Mod
    {
        QString id;
        QString dir;
        QString name;
        QString description;
        QString author;
        QString version;
        QHash<QString, QString> hooks; // hook -> absolute file
        QStringList errors;
    };

    void scan();
    void rewatch();
    QStringList enabledIds() const;

    QString m_root;
    QList<Mod> m_mods;
    int m_revision = 0;
    int m_errorRevision = 0;
    QFileSystemWatcher m_watcher;
    QTimer m_reloadTimer;
};
