// SyncCam browser camera: every photo and video this iPhone takes is kept
// in the browser's own storage (IndexedDB) the moment it's captured. That
// copy is the backup: it survives a dropped connection, a closed tab or a
// reload, uploads are retried from it, and the user saves it to Photos from
// the "On this iPhone" list.
'use strict';

const Store = (() => {
  const DB = 'synccam', TABLE = 'captures';
  let dbp = null;
  let memory = null; // fallback when IndexedDB is unavailable (private mode)

  function db() {
    if (!dbp) {
      dbp = new Promise((resolve, reject) => {
        if (!window.indexedDB) return reject(new Error('no IndexedDB'));
        const r = indexedDB.open(DB, 1);
        r.onupgradeneeded = () => r.result.createObjectStore(TABLE, { keyPath: 'id' });
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
      }).catch((e) => { memory = new Map(); throw e; });
      // Ask Safari not to evict these files under storage pressure.
      if (navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(() => {});
    }
    return dbp;
  }

  async function tx(mode, fn) {
    const d = await db();
    return new Promise((resolve, reject) => {
      const t = d.transaction(TABLE, mode);
      const out = fn(t.objectStore(TABLE));
      t.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
      t.onerror = () => reject(t.error);
      t.onabort = () => reject(t.error || new Error('storage full'));
    });
  }

  return {
    /** Keeps a capture. Returns false if it could only be kept in memory. */
    async put(rec) {
      try {
        await tx('readwrite', (s) => s.put(rec));
        return true;
      } catch (_) {
        (memory || (memory = new Map())).set(rec.id, rec);
        return false;
      }
    },
    async list() {
      try {
        const all = await tx('readonly', (s) => s.getAll());
        return [...(all || []), ...(memory ? memory.values() : [])].sort((a, b) => b.created - a.created);
      } catch (_) {
        return memory ? [...memory.values()].sort((a, b) => b.created - a.created) : [];
      }
    },
    async update(id, patch) {
      if (memory && memory.has(id)) return Object.assign(memory.get(id), patch);
      try {
        const d = await db();
        await new Promise((resolve, reject) => {
          const t = d.transaction(TABLE, 'readwrite');
          const s = t.objectStore(TABLE);
          const g = s.get(id);
          g.onsuccess = () => { if (g.result) s.put(Object.assign(g.result, patch)); };
          t.oncomplete = resolve;
          t.onerror = () => reject(t.error);
        });
      } catch (_) {}
    },
    async remove(id) {
      if (memory) memory.delete(id);
      try { await tx('readwrite', (s) => s.delete(id)); } catch (_) {}
    },
    async usage() {
      try {
        const e = await navigator.storage.estimate();
        return { used: e.usage || 0, quota: e.quota || 0 };
      } catch (_) {
        return { used: 0, quota: 0 };
      }
    },
  };
})();
