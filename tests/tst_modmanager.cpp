#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>

#include "app/editor/ModManager.h"

class ModManagerTest : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();
    void scansFoldersAndGatesOnEnabled();
    void rejectsHookFilesOutsideTheMod();
    void reloadPicksUpNewModsAndChangesUrls();
    void settingsAndMessages();

private:
    static void write(const QString &path, const QByteArray &content);

    QString m_org;
    QString m_app;
};

void ModManagerTest::write(const QString &path, const QByteArray &content)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(content);
}

void ModManagerTest::init()
{
    m_org = QCoreApplication::organizationName();
    m_app = QCoreApplication::applicationName();
    QStandardPaths::setTestModeEnabled(true);
    QCoreApplication::setOrganizationName(QStringLiteral("DriftTest"));
    QCoreApplication::setApplicationName(QStringLiteral("DriftTestMods"));
    QSettings().remove(QStringLiteral("Mods"));
}

void ModManagerTest::cleanup()
{
    QSettings().remove(QStringLiteral("Mods"));
    QCoreApplication::setOrganizationName(m_org);
    QCoreApplication::setApplicationName(m_app);
}

// A mod is found by its folder; a hook is found by its conventional file name or by mod.json; and
// nothing loads until the mod is switched on.
void ModManagerTest::scansFoldersAndGatesOnEnabled()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString root = dir.path();
    write(root + "/diamonds/TimelineClip.qml", "import QtQuick\nItem {}\n");
    write(root + "/docking/mod.json",
          R"({"name":"Panel docking","version":"1.2","author":"me",
              "hooks":{"panel":"ui/Handle.qml","app":"Missing.qml","bogus":"X.qml"}})");
    write(root + "/docking/ui/Handle.qml", "import QtQuick\nItem {}\n");
    QDir().mkpath(root + "/not-a-mod");
    QDir().mkpath(root + "/_disabled");
    write(root + "/_disabled/App.qml", "import QtQuick\nItem {}\n");

    ModManager manager(nullptr, root);
    const QVariantList mods = manager.mods();
    QCOMPARE(mods.size(), 2);

    const QVariantMap diamonds = mods.at(0).toMap();
    QCOMPARE(diamonds.value("id").toString(), QStringLiteral("diamonds"));
    QCOMPARE(diamonds.value("name").toString(), QStringLiteral("diamonds"));
    QCOMPARE(diamonds.value("hooks").toStringList(), QStringList{QStringLiteral("timelineClip")});
    QCOMPARE(diamonds.value("enabled").toBool(), false);
    QVERIFY(diamonds.value("errors").toStringList().isEmpty());

    const QVariantMap docking = mods.at(1).toMap();
    QCOMPARE(docking.value("name").toString(), QStringLiteral("Panel docking"));
    QCOMPARE(docking.value("version").toString(), QStringLiteral("1.2"));
    QCOMPARE(docking.value("hooks").toStringList(), QStringList{QStringLiteral("panel")});
    // The missing file and the unknown hook are both reported.
    QCOMPARE(docking.value("errors").toStringList().size(), 2);

    // Off by default.
    QVERIFY(!manager.hasHook(QStringLiteral("timelineClip")));
    QVERIFY(manager.hookEntries(QStringLiteral("timelineClip")).isEmpty());

    QSignalSpy changed(&manager, &ModManager::modsChanged);
    manager.setEnabled(QStringLiteral("diamonds"), true);
    QCOMPARE(changed.count(), 1);
    QVERIFY(manager.isEnabled(QStringLiteral("diamonds")));
    QVERIFY(manager.hasHook(QStringLiteral("timelineClip")));
    QVERIFY(!manager.hasHook(QStringLiteral("panel")));
    const QVariantList entries = manager.hookEntries(QStringLiteral("timelineClip"));
    QCOMPARE(entries.size(), 1);
    QCOMPARE(entries.first().toMap().value("modId").toString(), QStringLiteral("diamonds"));
    const QUrl url = entries.first().toMap().value("url").toUrl();
    QCOMPARE(QFileInfo(url.toLocalFile()).fileName(), QStringLiteral("TimelineClip.qml"));
    QVERIFY(QFileInfo::exists(url.toLocalFile()));

    // The choice is stored, so the next launch has it.
    ModManager again(nullptr, root);
    QVERIFY(again.hasHook(QStringLiteral("timelineClip")));

    manager.setEnabled(QStringLiteral("diamonds"), false);
    QVERIFY(!manager.hasHook(QStringLiteral("timelineClip")));
}

void ModManagerTest::rejectsHookFilesOutsideTheMod()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString root = dir.path() + "/mods";
    write(dir.path() + "/elsewhere.qml", "import QtQuick\nItem {}\n");
    write(root + "/sneaky/mod.json", R"({"hooks":{"app":"../../elsewhere.qml"}})");

    ModManager manager(nullptr, root);
    QCOMPARE(manager.mods().size(), 1);
    const QVariantMap mod = manager.mods().first().toMap();
    QVERIFY(mod.value("hooks").toStringList().isEmpty());
    QCOMPARE(mod.value("errors").toStringList().size(), 1);
    manager.setEnabled(QStringLiteral("sneaky"), true);
    QVERIFY(!manager.hasHook(QStringLiteral("app")));
}

// reload() tells hosts to let go first, then rescans; every reload hands out a different URL so
// an edited file is never served from a cache.
void ModManagerTest::reloadPicksUpNewModsAndChangesUrls()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString root = dir.path();
    write(root + "/one/App.qml", "import QtQuick\nItem {}\n");

    ModManager manager(nullptr, root);
    manager.setEnabled(QStringLiteral("one"), true);
    const QUrl before = manager.hookEntries(QStringLiteral("app")).first().toMap().value("url").toUrl();

    QStringList order;
    connect(&manager, &ModManager::aboutToReload, this, [&order] { order << QStringLiteral("about"); });
    connect(&manager, &ModManager::componentCacheStale, this, [&order] { order << QStringLiteral("cache"); });
    connect(&manager, &ModManager::modsChanged, this, [&order] { order << QStringLiteral("changed"); });

    write(root + "/two/App.qml", "import QtQuick\nItem {}\n");
    const int revision = manager.revision();
    manager.reload();
    QCOMPARE(order, (QStringList{QStringLiteral("about"), QStringLiteral("cache"), QStringLiteral("changed")}));
    QCOMPARE(manager.revision(), revision + 1);
    QCOMPARE(manager.mods().size(), 2);

    const QUrl after = manager.hookEntries(QStringLiteral("app")).first().toMap().value("url").toUrl();
    QVERIFY(before != after);
    QCOMPARE(before.toLocalFile(), after.toLocalFile());

    // A load error lands on the mod's row without triggering another reload.
    QSignalSpy changed(&manager, &ModManager::modsChanged);
    QSignalSpy errors(&manager, &ModManager::errorsChanged);
    manager.reportError(QStringLiteral("one"), QStringLiteral("app"), QStringLiteral("broken"));
    manager.reportError(QStringLiteral("one"), QStringLiteral("app"), QStringLiteral("broken"));
    QCOMPARE(changed.count(), 0);
    QCOMPARE(errors.count(), 1);
    QCOMPARE(manager.mods().first().toMap().value("errors").toStringList().size(), 1);
}

void ModManagerTest::settingsAndMessages()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    ModManager manager(nullptr, dir.path());

    QCOMPARE(manager.setting(QStringLiteral("m"), QStringLiteral("size"), 3).toInt(), 3);
    manager.setSetting(QStringLiteral("m"), QStringLiteral("size"), 7);
    QCOMPARE(manager.setting(QStringLiteral("m"), QStringLiteral("size"), 3).toInt(), 7);
    QCOMPARE(manager.setting(QStringLiteral("other"), QStringLiteral("size"), 3).toInt(), 3);

    QSignalSpy messages(&manager, &ModManager::message);
    manager.post(QStringLiteral("m"), QStringLiteral("drag"), 42);
    QCOMPARE(messages.count(), 1);
    QCOMPARE(messages.first().at(0).toString(), QStringLiteral("m"));
    QCOMPARE(messages.first().at(1).toString(), QStringLiteral("drag"));
    QCOMPARE(messages.first().at(2).toInt(), 42);
}

QTEST_GUILESS_MAIN(ModManagerTest)
#include "tst_modmanager.moc"
