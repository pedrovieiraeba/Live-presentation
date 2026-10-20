# 0002 — Persistência em SQLite com documentos JSON versionados

**Status:** aceita (Fase 1)

## Decisão
- SQLite via API C do sistema (`SQLite3` no macOS), encapsulado em `SQLiteDatabase`,
  acessado apenas pelo actor `LibraryStore` (fora da main thread, acesso serializado).
- WAL + `synchronous=NORMAL`; `foreign_keys=ON`.
- Migrações por `PRAGMA user_version`, cada uma numa transação; migrações publicadas
  nunca são editadas. Banco de versão mais nova é recusado com mensagem clara.
- Apresentações e temas guardados como JSON (`document`) + colunas de metadados para
  listagem (nome, datas, nº de slides) e `document_version`.
- Decodificação tolerante (`decodeIfPresent` com padrões) para evoluir o formato.
- Mídia (Fase 2) ficará no disco, referenciada por caminho/bookmark; nunca dentro do banco.

## Alternativas consideradas
- Core Data / SwiftData: mais acoplamento e migrações menos explícitas.
- Esquema totalmente normalizado (slides em tabela própria): mais complexidade sem ganho
  para documentos que sempre são lidos inteiros.

## Consequências
- Backup simples (um arquivo); consultas por conteúdo de slide exigirão FTS numa
  migração futura.
