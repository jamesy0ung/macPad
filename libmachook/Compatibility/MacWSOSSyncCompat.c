#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// os_sync_wait_on_address and its wake/timeout siblings first shipped in
// macOS 14.4. Qt 6 (IDA Professional 9.5's QtCore, minos 12.0, SDK 14.5) weak-
// imports them and calls _os_sync_wait_on_address unconditionally from
// QLatch::waitInternal. On the Ventura 13.4 rootfs the weak import binds to
// NULL; runtime 2026-11-11: SIGSEGV pc=0x0 lr=QtCore QLatch::waitInternal+0x3c
// on a QThreadPool worker. Apple builds these on the ulock primitives that
// Ventura already exports, so provide exactly that mapping and fill only GOT
// slots that dyld left NULL. A system that has the real functions is untouched.

extern int __ulock_wait2(uint32_t operation, void *address, uint64_t value,
                         uint64_t timeoutNanoseconds, uint64_t value2);
extern int __ulock_wake(uint32_t operation, void *address, uint64_t wakeValue);

enum {
    MacWSULCompareAndWait = 1,
    MacWSULCompareAndWaitShared = 3,
    MacWSULCompareAndWait64 = 5,
    MacWSULCompareAndWait64Shared = 6,
    MacWSULFWakeAll = 0x100,
    MacWSOSSyncShared = 1,
};

static int MacWSOSSyncOperation(size_t size, uint32_t flags, uint32_t *out) {
    if ((flags & ~(uint32_t)MacWSOSSyncShared) != 0) return EINVAL;
    bool shared = (flags & MacWSOSSyncShared) != 0;
    if (size == 4) {
        *out = shared ? MacWSULCompareAndWaitShared : MacWSULCompareAndWait;
    } else if (size == 8) {
        *out = shared ? MacWSULCompareAndWait64Shared : MacWSULCompareAndWait64;
    } else {
        return EINVAL;
    }
    return 0;
}

static int MacWSOSSyncWait(void *address, uint64_t value, size_t size,
                           uint32_t flags, uint64_t timeoutNanoseconds) {
    uint32_t operation = 0;
    int error = MacWSOSSyncOperation(size, flags, &operation);
    if (error != 0 || !address || ((uintptr_t)address % size) != 0) {
        errno = error ? error : EINVAL;
        return -1;
    }
    int result = __ulock_wait2(operation, address, value, timeoutNanoseconds, 0);
    if (result < 0 && errno == EFAULT) {
        // ulock copies the value in without faulting; touch the page and
        // retry once, as the libplatform ulock callers do.
        if (size == 4) (void)*(volatile uint32_t *)address;
        else (void)*(volatile uint64_t *)address;
        result = __ulock_wait2(operation, address, value, timeoutNanoseconds, 0);
    }
    return result;
}

static int macws_os_sync_wait_on_address(void *address, uint64_t value,
                                         size_t size, uint32_t flags) {
    return MacWSOSSyncWait(address, value, size, flags, 0);
}

static int macws_os_sync_wait_on_address_with_timeout(
        void *address, uint64_t value, size_t size, uint32_t flags,
        uint32_t clockID, uint64_t timeoutNanoseconds) {
    // OS_CLOCK_MACH_ABSOLUTE_TIME is the only clock the API defines.
    if (clockID != 32 || timeoutNanoseconds == 0) {
        errno = EINVAL;
        return -1;
    }
    return MacWSOSSyncWait(address, value, size, flags, timeoutNanoseconds);
}

static int MacWSOSSyncWake(void *address, size_t size, uint32_t flags,
                           uint32_t extra) {
    uint32_t operation = 0;
    int error = MacWSOSSyncOperation(size, flags, &operation);
    if (error != 0 || !address) {
        errno = error ? error : EINVAL;
        return -1;
    }
    return __ulock_wake(operation | extra, address, 0);
}

static int macws_os_sync_wake_by_address_any(void *address, size_t size,
                                             uint32_t flags) {
    return MacWSOSSyncWake(address, size, flags, 0);
}

static int macws_os_sync_wake_by_address_all(void *address, size_t size,
                                             uint32_t flags) {
    return MacWSOSSyncWake(address, size, flags, MacWSULFWakeAll);
}

static const struct {
    const char *name;
    void *replacement;
} MacWSOSSyncImports[] = {
    {"_os_sync_wait_on_address", (void *)macws_os_sync_wait_on_address},
    {"_os_sync_wait_on_address_with_timeout",
     (void *)macws_os_sync_wait_on_address_with_timeout},
    {"_os_sync_wake_by_address_any", (void *)macws_os_sync_wake_by_address_any},
    {"_os_sync_wake_by_address_all", (void *)macws_os_sync_wake_by_address_all},
};

static void *MacWSOSSyncReplacement(const char *name) {
    for (size_t i = 0;
         i < sizeof(MacWSOSSyncImports) / sizeof(MacWSOSSyncImports[0]); i++)
        if (strcmp(name, MacWSOSSyncImports[i].name) == 0)
            return MacWSOSSyncImports[i].replacement;
    return NULL;
}

static void MacWSOSSyncFillSlot(void **slot, void *replacement, bool authenticated) {
    uintptr_t current = (uintptr_t)*slot;
#if __has_feature(ptrauth_calls)
    current = (uintptr_t)ptrauth_strip((void *)current, ptrauth_key_asia);
#endif
    if (current != 0) return; // dyld bound a real implementation.
    void *value = replacement;
#if __has_feature(ptrauth_calls)
    value = ptrauth_strip(value, ptrauth_key_asia);
    if (authenticated)
        value = ptrauth_sign_unauthenticated(value, ptrauth_key_asia, slot);
#else
    (void)authenticated;
#endif
    long pageSize = getpagesize();
    uintptr_t page = (uintptr_t)slot & ~((uintptr_t)pageSize - 1);
    if (mprotect((void *)page, (size_t)pageSize, PROT_READ | PROT_WRITE) != 0)
        return;
    *slot = value;
    (void)mprotect((void *)page, (size_t)pageSize, PROT_READ);
}

static void MacWSOSSyncImageAdded(const struct mach_header *header,
                                  intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *dynamicSymbols = NULL;
    const struct load_command *command = (const struct load_command *)(header64 + 1);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64 &&
            !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT))
            linkedit = (const struct segment_command_64 *)command;
        else if (command->cmd == LC_SYMTAB)
            symbols = (const struct symtab_command *)command;
        else if (command->cmd == LC_DYSYMTAB)
            dynamicSymbols = (const struct dysymtab_command *)command;
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    if (!linkedit || !symbols || !dynamicSymbols) return;
    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbolTable = (const struct nlist_64 *)(linkeditBase + symbols->symoff);
    const char *stringTable = (const char *)(linkeditBase + symbols->stroff);
    const uint32_t *indirectTable =
        (const uint32_t *)(linkeditBase + dynamicSymbols->indirectsymoff);

    command = (const struct load_command *)(header64 + 1);
    for (uint32_t i = 0; i < header64->ncmds; i++,
         command = (const struct load_command *)((const uint8_t *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS)
                continue;
            bool authenticated = strncmp(section->sectname, "__auth_got", 16) == 0;
            void **slots = (void **)((uintptr_t)slide + section->addr);
            size_t count = (size_t)(section->size / sizeof(void *));
            for (size_t n = 0; n < count; n++) {
                uint32_t indirectIndex = section->reserved1 + (uint32_t)n;
                if (indirectIndex >= dynamicSymbols->nindirectsyms) break;
                uint32_t symbolIndex = indirectTable[indirectIndex];
                if ((symbolIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) != 0 ||
                    symbolIndex >= symbols->nsyms)
                    continue;
                uint32_t stringOffset = symbolTable[symbolIndex].n_un.n_strx;
                if (stringOffset >= symbols->strsize) continue;
                void *replacement = MacWSOSSyncReplacement(stringTable + stringOffset);
                if (replacement) MacWSOSSyncFillSlot(&slots[n], replacement, authenticated);
            }
        }
    }
}

__attribute__((constructor)) static void MacWSInstallOSSyncCompat(void) {
    if (dlsym(RTLD_DEFAULT, "os_sync_wait_on_address")) return;
    _dyld_register_func_for_add_image(MacWSOSSyncImageAdded);
}
