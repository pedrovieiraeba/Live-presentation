import Foundation

/// Migrações de esquema versionadas por `PRAGMA user_version`. Cada migração é
/// aplicada uma única vez, em ordem, dentro de uma transação. Nunca edite uma
/// migração já publicada: acrescente uma nova.
enum Migrations {
    static let all: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE presentations (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            slide_count INTEGER NOT NULL DEFAULT 0,
            document_version INTEGER NOT NULL,
            document TEXT NOT NULL
        );
        CREATE INDEX presentations_updated_at ON presentations(updated_at DESC);

        CREATE TABLE themes (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            document TEXT NOT NULL
        );

        CREATE TABLE playlists (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            position INTEGER NOT NULL
        );

        CREATE TABLE playlist_entries (
            playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            presentation_id TEXT NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
            PRIMARY KEY (playlist_id, position)
        );

        CREATE TABLE session_state (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.userVersion
        guard current <= latestVersion else {
            throw PersistenceError.databaseFromNewerVersion(found: current, supported: latestVersion)
        }
        for migration in all where migration.version > current {
            try db.transaction {
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
        }
    }
}
