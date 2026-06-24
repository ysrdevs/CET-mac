/**
 * RED4ext Hooks for macOS - Frida Gadget Implementation
 * 
 * This script implements the RED4ext hook system using Frida's Interceptor API,
 * bypassing Apple Silicon's W^X enforcement through JIT-based trampolines.
 * 
 * @version 1.1.0
 * @author RED4ext macOS Port
 */

'use strict';

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
    // Log level: 0=errors only, 1=info, 2=debug, 3=trace
    logLevel: 1,
    
    // Log prefix for all messages
    logPrefix: '[RED4ext-Frida]',
    
    // Module name to hook (main game executable)
    targetModule: 'Cyberpunk2077',
    
    // Hook offsets from __TEXT segment base
    hooks: {
        // Main function - App startup/shutdown
        0x0E54032B: { name: 'Main', offset: 0x31E18, enabled: true },
        
        // CGameApplication::AddState - Game state management
        0xFBC216B3: { name: 'CGameApplication_AddState', offset: 0x3F22E98, enabled: true },
        
        // Global::ExecuteProcess - Script compilation redirect
        0x835D1F2F: { name: 'Global_ExecuteProcess', offset: 0x1D46808, enabled: true },
        
        // CBaseEngine::InitScripts - Script initialization
        0xAB652585: { name: 'CBaseEngine_InitScripts', offset: 0x3D8C1A0, enabled: true },
        
        // CBaseEngine::LoadScripts - Script loading
        0xD4CB1D59: { name: 'CBaseEngine_LoadScripts', offset: 0x3D9A03C, enabled: true },
        
        // ScriptValidator::Validate - Script validation
        0x359024C2: { name: 'ScriptValidator_Validate', offset: 0x3D96BFC, enabled: true },
        
        // AssertionFailed - Assertion logging
        0xFF6B0CB1: { name: 'AssertionFailed', offset: 0x3C3D4C, enabled: true },
        
        // GameInstance::CollectSaveableSystems - Save system
        0xC0886390: { name: 'GameInstance_CollectSaveableSystems', offset: 0x87FEC, enabled: true },
        
        // GsmState_SessionActive::ReportErrorCode - Session state
        0x7FA31576: { name: 'GsmState_SessionActive_ReportErrorCode', offset: 0x3F5E9B0, enabled: true },
        
        // =====================================================================
        // TweakXL-specific hooks (TweakDB functions)
        // NOTE: Offsets need to be found via reverse engineering
        // =====================================================================
        
        // TweakDB_Init - Database initialization (hash: 3062572522)
        0xB6832FEA: { name: 'TweakDB_Init', offset: 0x0, enabled: false },
        
        // TweakDB_Load - Load optimized DB (hash: 3602585178)
        0xD6B1DB5A: { name: 'TweakDB_Load', offset: 0x0, enabled: false },
        
        // TweakDB_TryLoad - Try loading DB (hash: 3512345737)
        0xD16A2999: { name: 'TweakDB_TryLoad', offset: 0x0, enabled: false },
        
        // TweakDB_CreateRecord - Create DB record (hash: 838931066)
        0x31FB0F6A: { name: 'TweakDB_CreateRecord', offset: 0x0, enabled: false },
        
        // TweakDBID_Derive - Derive TweakDB ID (hash: 326438016)
        0x137620C0: { name: 'TweakDBID_Derive', offset: 0x0, enabled: false },
    }
};

// ============================================================================
// Logging
// ============================================================================

const LogLevel = {
    ERROR: 0,
    INFO: 1,
    DEBUG: 2,
    TRACE: 3
};

function log(level, message) {
    if (level <= CONFIG.logLevel) {
        const prefix = level === LogLevel.ERROR ? '[ERROR]' : 
                       level === LogLevel.DEBUG ? '[DEBUG]' : 
                       level === LogLevel.TRACE ? '[TRACE]' : '';
        console.log(`${CONFIG.logPrefix} ${prefix} ${message}`.trim());
    }
}

function logError(msg) { log(LogLevel.ERROR, msg); }
function logInfo(msg) { log(LogLevel.INFO, msg); }
function logDebug(msg) { log(LogLevel.DEBUG, msg); }
function logTrace(msg) { log(LogLevel.TRACE, msg); }

// ============================================================================
// Safe Memory Access Utilities
// ============================================================================

function safeReadPointer(ptr) {
    try {
        if (ptr.isNull()) return null;
        // Check if pointer looks valid (in reasonable address range)
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readPointer();
    } catch (e) {
        return null;
    }
}

function safeReadCString(ptr, maxLen = 256) {
    try {
        if (ptr.isNull()) return null;
        const addr = ptr.toUInt32 ? ptr.toUInt32() : parseInt(ptr.toString());
        if (addr < 0x1000 || addr > 0x7FFFFFFFFFFF) return null;
        return ptr.readCString(maxLen);
    } catch (e) {
        return null;
    }
}

function safeReadInt32(ptr) {
    try {
        if (ptr.isNull()) return null;
        return ptr.toInt32();
    } catch (e) {
        return null;
    }
}

function formatPtr(ptr) {
    if (!ptr) return 'null';
    try {
        return ptr.toString();
    } catch (e) {
        return 'invalid';
    }
}

// ============================================================================
// Module Resolution
// ============================================================================

let moduleBase = null;
let hookCount = 0;
let hookStats = {};

function getModuleBase() {
    if (moduleBase !== null) {
        return moduleBase;
    }
    
    const modules = Process.enumerateModules();
    
    for (const mod of modules) {
        if (mod.name.includes(CONFIG.targetModule)) {
            moduleBase = mod.base;
            logInfo(`Found module '${mod.name}' at base ${mod.base}`);
            return moduleBase;
        }
    }
    
    // Fallback: use the first module (main executable)
    if (modules.length > 0) {
        moduleBase = modules[0].base;
        logInfo(`Using fallback module '${modules[0].name}' at base ${modules[0].base}`);
        return moduleBase;
    }
    
    logError('Could not find target module!');
    return null;
}

// ============================================================================
// Hook Handlers
// ============================================================================

/**
 * Hook: Main
 */
function hookMain(address) {
    let gameStartTime = null;
    
    Interceptor.attach(address, {
        onEnter: function(args) {
            gameStartTime = Date.now();
            logInfo('Main() called - Game starting');
            hookStats['Main'] = (hookStats['Main'] || 0) + 1;
        },
        onLeave: function(retval) {
            const elapsed = gameStartTime ? (Date.now() - gameStartTime) : 0;
            logInfo(`Main() returned after ${elapsed}ms - Game shutting down`);
        }
    });
}

/**
 * Hook: CGameApplication::AddState
 */
function hookCGameApplication_AddState(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AddState'] = (hookStats['AddState'] || 0) + 1;
            logInfo('CGameApplication::AddState called');
            logTrace(`  this: ${formatPtr(args[0])}, state: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logTrace(`CGameApplication::AddState returned: ${retval}`);
        }
    });
}

/**
 * Hook: Global::ExecuteProcess
 */
function hookGlobal_ExecuteProcess(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ExecuteProcess'] = (hookStats['ExecuteProcess'] || 0) + 1;
            
            // Try to read command string safely
            const commandPtr = args[1];
            let commandStr = null;
            
            if (commandPtr && !commandPtr.isNull()) {
                // CString typically has char* at offset 0 or has inline storage
                const innerPtr = safeReadPointer(commandPtr);
                if (innerPtr) {
                    commandStr = safeReadCString(innerPtr);
                }
            }
            
            if (commandStr) {
                logInfo(`ExecuteProcess: ${commandStr}`);
                if (commandStr.includes('scc')) {
                    logInfo('  -> Script compiler detected');
                    this.isScc = true;
                }
            } else {
                logDebug('ExecuteProcess called (could not read command)');
            }
        },
        onLeave: function(retval) {
            if (this.isScc) {
                const success = retval.toInt32();
                logInfo(`Script compilation ${success ? 'succeeded' : 'failed'}`);
            }
        }
    });
}

/**
 * Hook: CBaseEngine::InitScripts
 */
function hookCBaseEngine_InitScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['InitScripts'] = (hookStats['InitScripts'] || 0) + 1;
            logInfo('CBaseEngine::InitScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::InitScripts completed');
        }
    });
}

/**
 * Hook: CBaseEngine::LoadScripts
 */
function hookCBaseEngine_LoadScripts(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['LoadScripts'] = (hookStats['LoadScripts'] || 0) + 1;
            logInfo('CBaseEngine::LoadScripts called');
        },
        onLeave: function(retval) {
            logInfo('CBaseEngine::LoadScripts completed');
        }
    });
}

/**
 * Hook: ScriptValidator::Validate
 */
function hookScriptValidator_Validate(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['Validate'] = (hookStats['Validate'] || 0) + 1;
            logDebug('ScriptValidator::Validate called');
        },
        onLeave: function(retval) {
            const result = safeReadInt32(retval);
            if (result !== null && result !== 0) {
                logInfo(`ScriptValidator::Validate found issues (code: ${result})`);
            }
        }
    });
}

/**
 * Hook: AssertionFailed
 */
function hookAssertionFailed(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['AssertionFailed'] = (hookStats['AssertionFailed'] || 0) + 1;
            
            logError('=== ASSERTION FAILED ===');
            
            const file = safeReadCString(args[0]);
            const line = safeReadInt32(args[1]);
            const expr = safeReadCString(args[2]);
            const msg = safeReadCString(args[3]);
            
            if (file) logError(`  File: ${file}`);
            if (line !== null) logError(`  Line: ${line}`);
            if (expr) logError(`  Expression: ${expr}`);
            if (msg) logError(`  Message: ${msg}`);
            
            logError('========================');
        }
    });
}

/**
 * Hook: GameInstance::CollectSaveableSystems
 */
function hookGameInstance_CollectSaveableSystems(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['CollectSaveableSystems'] = (hookStats['CollectSaveableSystems'] || 0) + 1;
            logDebug('GameInstance::CollectSaveableSystems called');
        }
    });
}

/**
 * Hook: GsmState_SessionActive::ReportErrorCode
 */
function hookGsmState_SessionActive_ReportErrorCode(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['ReportErrorCode'] = (hookStats['ReportErrorCode'] || 0) + 1;
            
            const errorCode = safeReadInt32(args[1]);
            if (errorCode !== null && errorCode !== 0) {
                logInfo(`GsmState_SessionActive::ReportErrorCode - Error: ${errorCode}`);
            }
        }
    });
}

// ============================================================================
// TweakXL Hook Handlers
// ============================================================================

/**
 * Hook: TweakDB_Init - Database initialization
 */
function hookTweakDB_Init(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Init'] = (hookStats['TweakDB_Init'] || 0) + 1;
            logInfo('TweakDB::Init called - TweakDB initializing');
            logTrace(`  this: ${formatPtr(args[0])}, arg1: ${formatPtr(args[1])}`);
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Init completed');
        }
    });
}

/**
 * Hook: TweakDB_Load - Load optimized database
 */
function hookTweakDB_Load(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_Load'] = (hookStats['TweakDB_Load'] || 0) + 1;
            logInfo('TweakDB::Load called - Loading TweakDB');
            
            // Try to read the path argument (CString)
            const pathPtr = args[1];
            if (pathPtr && !pathPtr.isNull()) {
                const innerPtr = safeReadPointer(pathPtr);
                if (innerPtr) {
                    const path = safeReadCString(innerPtr);
                    if (path) {
                        logInfo(`  Loading: ${path}`);
                    }
                }
            }
        },
        onLeave: function(retval) {
            logInfo('TweakDB::Load completed');
        }
    });
}

/**
 * Hook: TweakDB_TryLoad - Try loading database
 */
function hookTweakDB_TryLoad(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_TryLoad'] = (hookStats['TweakDB_TryLoad'] || 0) + 1;
            logInfo('TweakDB::TryLoad called');
        },
        onLeave: function(retval) {
            const success = retval.toInt32();
            logInfo(`TweakDB::TryLoad ${success ? 'succeeded' : 'failed'}`);
        }
    });
}

/**
 * Hook: TweakDB_CreateRecord - Create database record
 */
function hookTweakDB_CreateRecord(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDB_CreateRecord'] = (hookStats['TweakDB_CreateRecord'] || 0) + 1;
            logDebug('TweakDB::CreateRecord called');
            
            // args[0] = this (TweakDB*)
            // args[1] = recordType (uint32)
            // args[2] = recordId (TweakDBID)
            const recordType = safeReadInt32(args[1]);
            if (recordType !== null) {
                logTrace(`  recordType: 0x${recordType.toString(16)}`);
            }
        }
    });
}

/**
 * Hook: TweakDBID_Derive - Derive TweakDB ID from base
 */
function hookTweakDBID_Derive(address) {
    Interceptor.attach(address, {
        onEnter: function(args) {
            hookStats['TweakDBID_Derive'] = (hookStats['TweakDBID_Derive'] || 0) + 1;
            
            // args[2] = name string
            const nameStr = safeReadCString(args[2]);
            if (nameStr) {
                logTrace(`TweakDBID::Derive: ${nameStr}`);
            }
        }
    });
}

// ============================================================================
// Hook Installation
// ============================================================================

const hookFunctions = {
    'Main': hookMain,
    'CGameApplication_AddState': hookCGameApplication_AddState,
    'Global_ExecuteProcess': hookGlobal_ExecuteProcess,
    'CBaseEngine_InitScripts': hookCBaseEngine_InitScripts,
    'CBaseEngine_LoadScripts': hookCBaseEngine_LoadScripts,
    'ScriptValidator_Validate': hookScriptValidator_Validate,
    'AssertionFailed': hookAssertionFailed,
    'GameInstance_CollectSaveableSystems': hookGameInstance_CollectSaveableSystems,
    'GsmState_SessionActive_ReportErrorCode': hookGsmState_SessionActive_ReportErrorCode,
    // TweakXL hooks
    'TweakDB_Init': hookTweakDB_Init,
    'TweakDB_Load': hookTweakDB_Load,
    'TweakDB_TryLoad': hookTweakDB_TryLoad,
    'TweakDB_CreateRecord': hookTweakDB_CreateRecord,
    'TweakDBID_Derive': hookTweakDBID_Derive,
};

function installHooks() {
    console.log(`${CONFIG.logPrefix} ========================================`);
    console.log(`${CONFIG.logPrefix} RED4ext Frida Hooks - Initializing`);
    console.log(`${CONFIG.logPrefix} ========================================`);
    
    const base = getModuleBase();
    if (base === null) {
        logError('Failed to get module base address');
        return;
    }
    
    logInfo(`Module base: ${base}`);
    logInfo('');
    logInfo('Installing hooks...');
    
    for (const [hashStr, hookInfo] of Object.entries(CONFIG.hooks)) {
        const { name, offset, enabled } = hookInfo;
        
        if (!enabled) {
            logDebug(`  [SKIP] ${name} (disabled)`);
            continue;
        }
        
        const hookFunc = hookFunctions[name];
        if (!hookFunc) {
            logError(`  [ERROR] ${name} - No handler function`);
            continue;
        }
        
        try {
            const address = base.add(offset);
            hookFunc(address);
            hookCount++;
            logInfo(`  [OK] ${name} at ${address} (offset 0x${offset.toString(16)})`);
        } catch (e) {
            logError(`  [FAIL] ${name} - ${e.message}`);
        }
    }
    
    logInfo('');
    console.log(`${CONFIG.logPrefix} Hook installation complete: ${hookCount}/${Object.keys(CONFIG.hooks).length} hooks active`);
    console.log(`${CONFIG.logPrefix} ========================================`);
}

// ============================================================================
// Entry Point
// ============================================================================

installHooks();

// Export for external access
rpc.exports = {
    getHookCount: function() {
        return hookCount;
    },
    
    getHookStats: function() {
        return JSON.stringify(hookStats);
    },
    
    setLogLevel: function(level) {
        CONFIG.logLevel = level;
        return `Log level set to ${level}`;
    }
};

// ============================================================================
// CP2077SaveKit MINI-CET v3 -- universal RTTI call + enums + chains.
//   give <Items.NAME> <qty> | money <amt> | call <Class> <method> [args] | perks <n> | attrs <n> | relic <n>
// Resolves ANY method via CClass.funcs (+0x48), walks parents; live instance per class; enum args by name.
// ============================================================================
(function () {
    const OUT='/tmp/cp2077_out.txt', CMD='/tmp/cp2077_cmd.txt';
    function log(s){ try{const f=new File(OUT,'a');f.write(s+'\n');f.flush();f.close();}catch(e){} try{console.log('[MINICET] '+s);}catch(e2){} }
    function readFile(p){ try{return File.readAllText(p);}catch(e){return null;} }
    function clearFile(p){ try{const f=new File(p,'w');f.write('');f.close();}catch(e){} }
    function fnv(str){ let h=BigInt('0xCBF29CE484222325'); const P=BigInt('0x100000001b3'),M=(BigInt(1)<<BigInt(64))-BigInt(1); for(let i=0;i<str.length;i++){h^=BigInt(str.charCodeAt(i));h=(h*P)&M;} return h; }
    function u64(bi){ return uint64('0x'+bi.toString(16)); }
    function crc32(str){ let crc=0xFFFFFFFF; for(let i=0;i<str.length;i++){ let c=(crc^str.charCodeAt(i))&0xFF; for(let k=0;k<8;k++) c=(c&1)?(0xEDB88320^(c>>>1)):(c>>>1); crc=(crc>>>8)^c; } return (crc^0xFFFFFFFF)>>>0; }
    function tdbidBytes(n){ const h=crc32(n); return [h&0xff,(h>>>8)&0xff,(h>>>16)&0xff,(h>>>24)&0xff,n.length&0xff,0,0,0]; }
    const FV0=ptr('0x100000000');
    const T_I32='0xb9a127f5b4a621bf',T_U32='0x3d2e9dd9e3c28d8c',T_I64='0xb9902ff5b497bc24',T_U64='0x3d3f99d9e3d0f9f3',
          T_F32='0xb64f4a0accc8a8c5',T_BOOL='0xf7bdd5a7c820889d',T_CNAME='0xa5e23de2a2657af9',T_TDB='0x4072151ff3dcf7bc',T_ITEM='0xd15b2274885d7f7d';
    const PLAYER='0xcebecae898e55b86';
    try {
        const base=getModuleBase(); const execAddr=base.add(0x2173120);
        const Exec=new NativeFunction(execAddr,'uint64',['pointer','pointer','pointer','pointer','pointer']);
        let reg=null,GetClass=null,GetEnum=null;
        function ensureReg(){ if(reg) return; reg=new NativeFunction(base.add(0x2188e8c),'pointer',[])(); const rv=reg.readPointer();
            GetClass=new NativeFunction(rv.add(0x10).readPointer(),'pointer',['pointer','uint64']);
            GetEnum =new NativeFunction(rv.add(0x18).readPointer(),'pointer',['pointer','uint64']); }
        let player=null, playerVt=null, fromtd=null, depth=0, busy=false, lastCmd=''; const pendingQ=[];
        const playerCands=[], playerCandSet=new Set(); let devOwner=null;  // cached dev-data owner (the local player)
        function addCand(ctx){ const k=ctx.toString(); if(playerCandSet.has(k)) return; playerCandSet.add(k); playerCands.push(ctx); if(playerCands.length>8){ const old=playerCands.shift(); playerCandSet.delete(old.toString()); } }
        const instReg={}, seenVt=new Set(); let nameHookInstalled=false;
        const refcnt=Memory.alloc(8); refcnt.writeU32(0x100000); refcnt.add(4).writeU32(0x100000);
        function nameOf(metaObj){ try{ const gn=metaObj.readPointer().add(0x10).readPointer(); return '0x'+new NativeFunction(gn,'uint64',['pointer'])(metaObj).toString(16);}catch(e){return null;} }
        function hexp(pp,nn){ try{const b=new Uint8Array(pp.readByteArray(nn));let r='';for(let i=0;i<b.length;i++)r+=('0'+b[i].toString(16)).slice(-2)+' ';return r.trim();}catch(e){return 'ERR';} }
        function sigStr(fn){ try{ const pe=fn.add(0x28).readPointer(), pc=fn.add(0x30).readU32(); let p=[]; for(let i=0;i<pc;i++){ p.push(nameOf(pe.add(i*8).readPointer().readPointer())); } return 'params['+pc+']=['+p.join(',')+']'; }catch(e){ return 'sigErr'; } }
        function clsByName(n){ ensureReg(); const m=GetClass(reg,u64(fnv(n))); return m.isNull()?null:m; }
        // universal: find a method (CClassFunction*) by class name + short name, walking parents
        function resolveFunc(className, method){ let cls=clsByName(className); const mh=fnv(method);
            while(cls && !cls.isNull()){
                for(const off of [0x48, 0x58]){            // instance funcs, then STATIC funcs
                    const fp=cls.add(off).readPointer(); const n=cls.add(off+8).readU32();
                    if(!fp.isNull()){ for(let i=0;i<n;i++){ const f=fp.add(i*8).readPointer(); if(f.isNull())continue;
                        if(f.add(0x10).readU64().equals(u64(mh))){ const rp=f.add(0x18).readPointer(); return {fn:f, retType:rp.isNull()?ptr(0):rp.readPointer(), isStatic:(off===0x58)}; } } }
                }
                cls=cls.add(0x10).readPointer(); }            // parent
            return null; }
        // ===== Observe(class, method, cb): fire JS when the game runs a scripted/native function. =====
        // Built on the existing global-Executor hook below. methodHash=fnv(shortName) matches fn+0x10
        // (the same key resolveFunc uses); classHash=fnv(className) is matched against the instance's
        // class chain (walks parents, so subclasses match too). cb(ctx, frame, fn) runs BEFORE the
        // original. With no cb it's a throttled diagnostic that dumps ctx/frame/signature so we can
        // decode real args from reality first (verify-the-reference), then write real callbacks.
        let obsByMethod = {};   // '0x<methodHash>' -> [observer, ...]
        let obsCount = 0;
        function classIsA(meta, wantHash){ let c=meta, g=0; while(c && !c.isNull() && g++<24){ try{ if(nameOf(c)===wantHash) return true; }catch(e){ return false; } c=c.add(0x10).readPointer(); } return false; }
        function obsFire(ob, ctx, frame, fn){
            if(ob.diag && ob.hits<12){ ob.hits++;
                let sig=''; try{ sig=sigStr(fn); }catch(e){ sig='sigErr'; }
                let fr=''; try{ fr=hexp(frame,0x60); }catch(e){ fr='ERR'; }
                log('OBSERVE '+ob.className+'.'+ob.methodName+' #'+ob.hits+' ctx='+ctx+' frame='+frame+' '+sig);
                log('   frame[0x60]='+fr); }
            if(ob.cb){ try{ ob.cb(ctx, frame, fn); }catch(e){ log('observe cb err ('+ob.methodName+'): '+e); } }
        }
        // Register an observer. className=null -> match the method on ANY class. Returns the observer obj.
        function cmObserve(className, methodName, cb, opts){
            const mh='0x'+fnv(methodName).toString(16);
            const ch=className?('0x'+fnv(className).toString(16)):null;
            const ob={ classHash:ch, className:className||'*', methodName:methodName, cb:cb||null, hits:0, diag:(!cb)||!!(opts&&opts.diag) };
            (obsByMethod[mh]=obsByMethod[mh]||[]).push(ob); obsCount++;
            log('observe + '+ob.className+'.'+methodName+'  (methodHash '+mh+(ch?(', classHash '+ch):'')+')');
            return ob;
        }
        function cmUnobserve(){ obsByMethod={}; obsCount=0; log('observe: all cleared'); }
        // ===== script-object creation + field access (for building the native menu) =====
        // NO sig-scanned addresses (the JSON's CClass_CreateInstance hash is bogus on this binary - it points
        // at a parser). Instead use the CClass vtable, which we already call successfully (nameOf uses vt+0x10).
        // CClass vtable: SDK lists ConstructCls //D8, AllocMemory //E8, BUT the runtime vtable has a +0x08 shift
        // (virtual dtor takes TWO Itanium slots; confirmed: nameOf reads GetName at vt+0x10 though SDK says //08).
        // So runtime: ConstructCls @0xE0, AllocMemory @0xF0. CClass fields: parent@0x10, props@0x28, size@0x68.
        // createInstance = AllocMemory() (allocs sizeof from the class allocator) + ConstructCls(mem).
        function createInstance(className){ const cls=clsByName(className); if(!cls) return null;
            try{ const vt=cls.readPointer();
                const allocFn=new NativeFunction(vt.add(0xf0).readPointer(),'pointer',['pointer']);   // CClass::AllocMemory() (SDK 0xE8 +8)
                const mem=allocFn(cls); if(!mem||mem.isNull()){ log('createInstance: AllocMemory null'); return null; }
                const ctorFn=new NativeFunction(vt.add(0xe0).readPointer(),'void',['pointer','pointer']); // ConstructCls(mem) (SDK 0xD8 +8)
                ctorFn(cls, mem); return mem;
            }catch(e){ log('createInstance err '+e); return null; } }
        // Resolve a field -> {off, type, typeName} via the manual props walk (inheritance via parent chain). No game func.
        function findProp(className, fieldName){ let cls=clsByName(className); if(!cls) return null; const want=u64(fnv(fieldName)); let guard=0;
            while(cls&&!cls.isNull()&&guard++<12){ const pp=cls.add(0x28).readPointer(), n=cls.add(0x30).readU32();
                for(let i=0;i<n;i++){ const pr=pp.add(i*8).readPointer(); if(pr.isNull())continue;
                    if(pr.add(0x08).readU64().equals(want)){ let tn='?'; try{tn=nameOf(pr.readPointer());}catch(e){} return {prop:pr, off:pr.add(0x20).readU32(), type:pr.readPointer(), typeName:tn}; } }
                cls=cls.add(0x10).readPointer(); }
            return null; }
        // get an INSTANCE's class meta (instance vtable GetType @ +0x08), and resolve a method on a known meta.
        function instType(inst){ try{ const vt=inst.readPointer(); return new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(inst); }catch(e){ return null; } }
        function resolveFuncMeta(meta, method){ const mh=fnv(method); let cls=meta;
            while(cls&&!cls.isNull()){ for(const off of [0x48,0x58]){ const fp=cls.add(off).readPointer(); const n=cls.add(off+8).readU32();
                if(!fp.isNull()){ for(let i=0;i<n;i++){ const f=fp.add(i*8).readPointer(); if(f.isNull())continue;
                    if(f.add(0x10).readU64().equals(u64(mh))){ const rp=f.add(0x18).readPointer(); return {fn:f, retType:rp.isNull()?ptr(0):rp.readPointer()}; } } } }
                cls=cls.add(0x10).readPointer(); }
            return null; }
        // enum member value by enum-type-name-hash + member name
        function resolveEnumByTypeHash(typeHashHex, member){ ensureReg(); const en=GetEnum(reg,uint64(typeHashHex)); if(en.isNull()) return null;
            const hp=en.add(0x28).readPointer(), n=en.add(0x30).readU32(), vp=en.add(0x38).readPointer(); const mh=fnv(member);
            for(let i=0;i<n;i++){ if(hp.add(i*8).readU64().equals(u64(mh))) return vp.add(i*8).readU64(); } return null; }
        function fromTDBID(tb,out){ const bc=Memory.alloc(32);let o=0;bc.writeU8(0x11);o++;for(let i=0;i<8;i++){bc.add(o).writeU8(tb[i]);o++;}bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90);fr.writePointer(bc);fr.add(0x40).writePointer(fromtd?fromtd.ctx:ptr(0));return Exec(fromtd.fn,fromtd.ctx,fr,out,fromtd.retType); }
        // generic invoke: fn(CClassFunction*), ctx, args[] strings -> 16-byte result buffer
        function callFunc(fn, ctx, retType, args){
            const pEntries=fn.add(0x28).readPointer(); const pCount=fn.add(0x30).readU32();
            const locals=Memory.alloc(0x40+args.length*0x20); const props=[];
            for(let i=0;i<args.length;i++){ if(i>=pCount) throw 'too many args (fn takes '+pCount+')';
                const prop=pEntries.add(i*8).readPointer(); const ptype=prop.readPointer(); const tn=nameOf(ptype);
                const off=0x20+i*0x20; const dst=locals.add(off); const a=args[i];
                if(typeof a==='object'&&a.raw){ Memory.copy(dst, a.raw, a.n||16); }
                else if(a[0]==='@'){ let inst; if(a==='@player') inst=player; else if(a==='@self') inst=ctx; else inst=ptr(a.slice(1));
                    if(!inst||inst.isNull()) throw 'no instance for '+a; dst.writePointer(inst); dst.add(8).writePointer(refcnt); }
                else if(tn===T_ITEM){ fromTDBID(tdbidBytes(a),dst); }
                else if(tn===T_I32||tn===T_U32){ dst.writeU32(parseInt(a)>>>0); }
                else if(tn===T_I64||tn===T_U64){ dst.writeU64(uint64(parseInt(a))); }
                else if(tn===T_F32){ dst.writeFloat(parseFloat(a)); }
                else if(tn===T_BOOL){ dst.writeU8((a==='true'||a==='1')?1:0); }
                else if(tn===T_CNAME){ dst.writeU64(u64(fnv(a))); }
                else if(tn===T_TDB){ const tb=tdbidBytes(a); for(let k=0;k<8;k++) dst.add(k).writeU8(tb[k]); }
                else { let ev=resolveEnumByTypeHash(tn, a); if(ev===null && /^-?\d+$/.test(a)) ev=uint64(parseInt(a)); if(ev!==null){ dst.writeU64(ev); } else throw 'unsupported arg type '+tn+' for "'+a+'"'; }
                const cp=Memory.alloc(0x30); cp.writePointer(ptype); cp.add(0x20).writeU32(off); props.push(cp); }
            const bc=Memory.alloc(16+args.length*9); let o=0; for(let i=0;i<args.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx.isNull?(ctx):ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function instOf(className){ const m=clsByName(className); if(!m) return null; const fv=m.sub(base).add(FV0).toString(16); return instReg[fv]||null; }
        function doGive(name,qty,forceBulk){ const e=resolveFunc('gameTransactionSystem','GiveItem'); if(!e){ log('GiveItem not found'); return; }
            const tx=instOf('gameTransactionSystem'); if(!tx){ log('no transaction system instance yet'); return; }
            const owner=authPlayer();   // authoritative local player (deterministic; avoids flaky transient puppets)
            const give=function(q){ const id=Memory.alloc(16); id.writeU64(0); id.add(8).writeU64(0); fromTDBID(tdbidBytes(name),id);
                return callFuncRaw(e.fn, tx, e.retType, [{kind:'handle',inst:owner},{kind:'item16',ptr:id},{kind:'i32',v:q}]); };
            let ok=0;
            // GiveItem's quantity arg is only honored for currency (money). For normal items it adds 1
            // regardless, so loop give(1) N times to actually deposit the requested count. Cap to avoid hangs.
            if(forceBulk){ ok=give(qty).readU8(); log('give '+name+' x'+qty+' (bulk) -> '+ok); }
            else { const n=Math.min(qty,9999); for(let k=0;k<n;k++){ if(give(1).readU8()) ok++; } log('give '+name+' x'+n+' -> '+ok+'/'+n); }
            if(!ok) log('  (0 added - bad item id? names start with "Items." e.g. Items.Preset_Lexington_Default)'); }
        // raw marshaller (pre-encoded values) for give chaining
        function callFuncRaw(fn, ctx, retType, items){ const pEntries=fn.add(0x28).readPointer();
            const locals=Memory.alloc(0x40+items.length*0x20); const props=[];
            for(let i=0;i<items.length;i++){ const prop=pEntries.add(i*8).readPointer(); const ptype=prop.readPointer(); const off=0x20+i*0x20; const dst=locals.add(off); const it=items[i];
                if(it.kind==='handle'){ dst.writePointer(it.inst); dst.add(8).writePointer(refcnt); }
                else if(it.kind==='item16'){ Memory.copy(dst, it.ptr, 16); }
                else if(it.kind==='i32'){ dst.writeU32(it.v>>>0); }
                const cp=Memory.alloc(0x30); cp.writePointer(ptype); cp.add(0x20).writeU32(off); props.push(cp); }
            const bc=Memory.alloc(16+items.length*9); let o=0; for(let i=0;i<items.length;i++){ bc.add(o).writeU8(0x18);o++; bc.add(o).writePointer(props[i]);o+=8; } bc.add(o).writeU8(0x26);
            const fr=Memory.alloc(0x90); fr.writePointer(bc); fr.add(0x10).writePointer(locals); fr.add(0x18).writePointer(locals); fr.add(0x40).writePointer(ctx);
            const res=Memory.alloc(16); res.writeU64(0); res.add(8).writeU64(0); Exec(fn, ctx, fr, res, retType); return res; }
        function sane(pp){ try{ return !pp.isNull() && pp.compare(ptr('0x10000'))>0 && pp.compare(ptr('0x800000000000'))<0; }catch(e){ return false; } }
        function getSystem(giBuf, className){    // giBuf = GetGame result buffer (a GameInstance wrapper)
            const cls=clsByName(className); if(!cls){ log('  class '+className+' not found'); return null; }
            for(const goff of [8, 0]){           // gameInstance ptr lives at wrapper+8 (per game's own code); fallback +0
                try{
                    const gi=giBuf.add(goff).readPointer(); if(!sane(gi)) continue;
                    const holder=gi.add(0x48).readPointer(); if(!sane(holder)) continue;
                    const cpp=holder.add(0xc0).readPointer(); if(!sane(cpp)) continue;
                    const container=cpp.readPointer(); if(!sane(container)) continue;
                    const cvt=container.readPointer(); if(!sane(cvt)) continue;
                    const getFn=new NativeFunction(cvt.add(0x10).readPointer(),'pointer',['pointer','pointer']);
                    const sys=getFn(container, cls); log('  getSystem('+className+') gi(+'+goff+')='+gi+' container='+container+' -> '+sys);
                    if(!sys.isNull()) return sys;
                }catch(e){ log('  getSystem gi+'+goff+' err: '+e); }
            }
            return null;
        }
        function probeFuncs(className, names){ for(const nm of names){ const e=resolveFunc(className,nm);
            if(e) log('    '+className+'.'+nm+' FOUND '+(e.isStatic?'[static]':'[inst]')+' ret='+(e.retType.isNull()?'void':nameOf(e.retType))+' '+sigStr(e.fn));
            else log('    '+className+'.'+nm+' (none)'); } }
        function resolveAny(classNames, method){ for(const c of classNames){ const e=resolveFunc(c,method); if(e){ e.cls=c; return e; } } return null; }
        // Get a scriptable system the way the VM does: GameInstance.GetScriptableSystemsContainer(gi).Get(name)
        function getScriptableSystem(giRes, sysName){
            const gsc=resolveAny(['GameInstance','ScriptGameInstance','gameScriptGameInstance'],'GetScriptableSystemsContainer');
            if(!gsc){ log('  GetScriptableSystemsContainer not found'); return null; }
            log('  GSC ['+gsc.cls+(gsc.isStatic?' static':' inst')+'] '+sigStr(gsc.fn));
            let cont=null;
            for(const nb of [8,16]){ try{ const r=callFunc(gsc.fn, player, gsc.retType, [{raw:giRes,n:nb}]);
                const c=r.readPointer(); log('  container(gi'+nb+')='+c); if(sane(c)){ cont=c; break; } }catch(e){ log('  GSC(gi'+nb+') err: '+e); } }
            if(!cont) return null;
            const get=resolveAny(['ScriptableSystemsContainer','gameScriptableSystemsContainer'],'Get');
            if(!get){ log('  container.Get not found'); return null; }
            log('  Get ['+get.cls+'] '+sigStr(get.fn));
            try{ const r=callFunc(get.fn, cont, get.retType, [sysName]); const sys=r.readPointer(); log('  '+sysName+' inst='+sys); return sane(sys)?sys:null; }
            catch(e){ log('  Get err: '+e); return null; }
        }
        // The owner the dev-data is keyed to is the local player puppet (one of several captured puppets
        // share its vtable). We can't pull it from the scriptable container (PlayerSystem isn't there),
        // so we probe owner candidates against GetDevelopmentData and cache the one that yields data.
        function getDevData(){
            const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg){ log('GetGame not found'); return null; }
            const giRes=callFunc(gg.fn, player, gg.retType, []);
            const sys=getScriptableSystem(giRes,'PlayerDevelopmentSystem');
            if(!sys){ log('could not get PlayerDevelopmentSystem instance'); return null; }
            const gdd=resolveFunc('PlayerDevelopmentSystem','GetDevelopmentData'); if(!gdd){ log('GetDevelopmentData not found'); return null; }
            const owners=[]; const ap=authPlayer(giRes); if(ap) owners.push(ap);   // authoritative local player first
            if(devOwner) owners.push(devOwner); if(player) owners.push(player); for(const c of playerCands) owners.push(c);
            const tried=new Set();
            for(const o of owners){ const k=o.toString(); if(tried.has(k)) continue; tried.add(k);
                try{ const r=callFunc(gdd.fn, sys, gdd.retType, ['@'+o]); const d=r.readPointer();
                    if(sane(d)){ devOwner=o; log('  devData='+d+' (owner '+o+', tried '+tried.size+')'); return d; } }
                catch(e){ log('  GetDevelopmentData('+o+') err: '+e); } }
            devOwner=null; log('  GetDevelopmentData: no owner of '+tried.size+' yielded data'); return null;
        }
        // ---- convenience-command helpers ----
        function getGI(){ const gg=resolveFunc('PlayerPuppet','GetGame'); if(!gg) return null; return callFunc(gg.fn, player, gg.retType, []); }
        function curPlayer(){ return devOwner||player; }
        // authoritative, deterministic local player (cpPlayerSystem.GetLocalPlayerControlledGameObject); falls back to captured
        function authPlayer(gi){ try{ gi=gi||getGI(); if(gi){ const p=getPlayerViaSystem(gi); if(p) return p; } }catch(e){} return curPlayer(); }
        // call a static GameInstance.<getter>(gi) -> system/facility ptr (same pattern as GetScriptableSystemsContainer)
        function getViaGetter(giRes, getterName){
            const g=resolveAny(['ScriptGameInstance','GameInstance','gameScriptGameInstance'], getterName);
            if(!g){ log('  getter '+getterName+' not found'); return null; }
            log('  '+getterName+' '+(g.isStatic?'[static]':'[inst]')+' '+sigStr(g.fn));
            for(const nb of [8,16]){ try{ const r=callFunc(g.fn, player, g.retType, [{raw:giRes,n:nb}]); const p=r.readPointer(); if(sane(p)) return p; }catch(e){ log('  '+getterName+'(gi'+nb+') err: '+e); } }
            return null;
        }
        // Authoritative local player via GameInstance.GetPlayerSystem(gi).<localPlayerGetter>() (probes the name).
        let _pgetter=null;
        function getPlayerViaSystem(gi){
            const ps=getViaGetter(gi,'GetPlayerSystem'); if(!ps){ log('  GetPlayerSystem not reachable'); return null; }
            const names=_pgetter?[_pgetter]:['GetLocalPlayerControlledGameObject','GetLocalPlayerMainGameObject','GetLocalPlayer','GetPlayerControlledGameObject','GetPlayer'];
            for(const cls of ['gamePlayerSystem','cpPlayerSystem','PlayerSystem']){
                for(const mn of names){ const m=resolveFunc(cls,mn); if(!m) continue;
                    try{ const r=callFunc(m.fn, ps, m.retType, []); const o=r.readPointer(); log('  '+cls+'.'+mn+' -> '+o); if(sane(o)){ _pgetter=mn; return o; } }
                    catch(e){ log('  '+cls+'.'+mn+' err '+e); } }
            }
            log('  no local-player getter resolved on the player system'); return null;
        }
        // godmode via the IsInvulnerable STAT (not the god-mode system). The damage pipeline's
        // InvulnerabilityCheck flags DealNoDamage when GetStatValue(player, IsInvulnerable) > 0. We grant it
        // with a +1 stat modifier through the StatsSystem (which responds to our entity id, like heal does).
        // Note: fall damage / scripted kills carry IgnoreImmortalityModes and bypass ALL god mode by design.
        // Apply/remove a status effect on the player (the proven CET approach for godmode/invisibility/etc).
        // ApplyStatusEffect(objID: entEntityID, statusEffectID: TweakDBID, ...rest optional - the VM defaults them).
        function statusApply(on, effectID){
            const gi=getGI(); if(!gi) return false;
            const p=authPlayer(gi); if(!p) return false;
            const geid=resolveAny(['gameObject','gameEntity'],'GetEntityID'); if(!geid) return false;
            const eid=callFunc(geid.fn, p, geid.retType, []);
            const ses=getSystemFlexible(gi,'gameStatusEffectSystem','GetStatusEffectSystem'); if(!ses) return false;
            const e=resolveAny(['gameStatusEffectSystem'], on?'ApplyStatusEffect':'RemoveStatusEffect'); if(!e) return false;
            try{ callFunc(e.fn, ses, e.retType, [{raw:eid,n:8}, effectID]); return true; }
            catch(ex){ log('status err: '+ex); return false; }
        }
        // Toggle a player status effect, reapplying on a tick (the game strips these on some transitions).
        const statusToggles={};   // effectID -> { on, timer }
        function toggleStatus(label, effectID, on){
            const st=statusToggles[effectID]||(statusToggles[effectID]={on:false,timer:null});
            st.on=on;
            const ok=statusApply(on, effectID);
            if(on){
                log('*** '+label+' '+(ok?'ON':'failed - StatusEffectSystem not reachable')+' ***');
                if(ok && !st.timer){ st.timer=setInterval(function(){ if(st.on) statusApply(true, effectID); }, 3000); }
            } else {
                if(st.timer){ clearInterval(st.timer); st.timer=null; }
                log('*** '+label+' '+(ok?'OFF':'off (StatusEffectSystem not reachable)')+' ***');
            }
        }
        function doGodmode(on){ toggleStatus('godmode', 'BaseStatusEffect.Invulnerable', on); }
        function doInfammo(on){ toggleStatus('infinite ammo', 'GameplayRestriction.InfiniteAmmo', on); }
        function doInvisible(on){
            toggleStatus('invisible', 'BaseStatusEffect.Cloaked', on);
            // Cloaked is only the visual camo; SetInvisible() is what actually breaks enemy detection.
            try{ const gi=getGI(); const p=authPlayer(gi);
                const si=resolveAny(['gameObject','gameEntity'],'SetInvisible'); if(si) callFunc(si.fn, p, si.retType, [on?'true':'false']);
                const uv=resolveAny(['gameObject','gameEntity'],'UpdateVisibility'); if(uv) callFunc(uv.fn, p, uv.retType, []);
            }catch(e){ log('invis visibility err: '+e); }
        }
        // --- world / misc cheats ---
        function doTime(h,m){
            const gi=getGI(); if(!gi){ log('time: no gi'); return; }
            const ts=getViaGetter(gi,'GetTimeSystem'); if(!ts){ log('time: TimeSystem not reachable'); return; }
            const e=resolveAny(['gameTimeSystem'],'SetGameTimeByHMS'); if(!e){ log('time: SetGameTimeByHMS not found'); return; }
            try{ callFunc(e.fn, ts, e.retType, [''+h, ''+m, '0']); log('*** time set to '+h+':'+(m<10?'0':'')+m+' ***'); }
            catch(ex){ log('time err: '+ex); }
        }
        function doSlowmo(on, factor){
            const gi=getGI(); if(!gi){ log('slowmo: no gi'); return; }
            const ts=getViaGetter(gi,'GetTimeSystem'); if(!ts){ log('slowmo: TimeSystem not reachable'); return; }
            if(on){ const e=resolveAny(['gameTimeSystem'],'SetTimeDilation'); if(!e){ log('slowmo: SetTimeDilation not found'); return; }
                try{ callFunc(e.fn, ts, e.retType, ['NightCityConsole', ''+(factor||0.3)]); log('*** slowmo ON ('+(factor||0.3)+'x) ***'); }catch(ex){ log('slowmo err: '+ex); } }
            else { const e=resolveAny(['gameTimeSystem'],'UnsetTimeDilation'); if(!e){ log('slowmo: UnsetTimeDilation not found'); return; }
                try{ callFunc(e.fn, ts, e.retType, ['NightCityConsole']); log('*** slowmo OFF ***'); }catch(ex){ log('slowmo err: '+ex); } }
        }
        function doNoPolice(on){
            const gi=getGI(); if(!gi){ log('nopolice: no gi'); return; }
            const p=authPlayer(gi); if(!p){ log('nopolice: no player'); return; }
            const gp=resolveAny(['gameObject','PlayerPuppet','gameEntity'],'GetPreventionSystem'); if(!gp){ log('nopolice: GetPreventionSystem not found'); return; }
            let ps=null; try{ ps=callFunc(gp.fn, p, gp.retType, []).readPointer(); }catch(ex){ log('nopolice: GetPreventionSystem err: '+ex); return; }
            if(!sane(ps)){ log('nopolice: no PreventionSystem instance'); return; }
            const e=resolveAny(['PreventionSystem','gamePreventionSystem'],'TogglePreventionSystem'); if(!e){ log('nopolice: TogglePreventionSystem not found'); return; }
            try{ callFunc(e.fn, ps, e.retType, [on?'false':'true']); log('*** police '+(on?'DISABLED':'enabled')+' ***'); }
            catch(ex){ log('nopolice err: '+ex); }
        }
        function doLevel(n){
            const dd=getDevData(); if(!dd){ log('level: no PlayerDevelopmentData'); return; }
            const sl=resolveAny(['PlayerDevelopmentData'],'SetLevel'); if(!sl){ log('level: SetLevel not found'); return; }
            log('  SetLevel '+sigStr(sl.fn));
            // (gamedataProficiencyType, Int32 level, telemetryLevelGainReason, Bool)
            try{ callFunc(sl.fn, dd, sl.retType, ['Level', ''+n, '0', 'true']); log('*** level set to '+n+' ***'); }
            catch(e){ log('level err: '+e); }
        }
        // street cred rides the same PlayerDevelopmentData.SetLevel path as level - only the
        // gamedataProficiencyType member differs ('StreetCred' vs 'Level'). Caps at 50; SetLevel clamps.
        function doStreetCred(n){
            const dd=getDevData(); if(!dd){ log('streetcred: no PlayerDevelopmentData'); return; }
            const sl=resolveAny(['PlayerDevelopmentData'],'SetLevel'); if(!sl){ log('streetcred: SetLevel not found'); return; }
            try{ callFunc(sl.fn, dd, sl.retType, ['StreetCred', ''+n, '0', 'true']); log('*** street cred set to '+n+' ***'); }
            catch(e){ log('streetcred err: '+e); }
        }
        const tpMarks={};   // name -> ArrayBuffer(16) saved Vector4 (session-only)
        function doTeleport(t){
            const gi=getGI(); if(!gi){ log('teleport: no GameInstance'); return; }
            const p=authPlayer(gi); if(!p){ log('teleport: no player'); return; }
            const gw=resolveAny(['gameObject','gameEntity'],'GetWorldPosition'); if(!gw){ log('teleport: GetWorldPosition not found'); return; }
            const cur=callFunc(gw.fn, p, gw.retType, []);   // current Vector4 (16B)
            const cx=cur.readFloat(), cy=cur.add(4).readFloat(), cz=cur.add(8).readFloat();
            const sub=t[1];
            if(sub==='save'&&t[2]){ tpMarks[t[2]]=cur.readByteArray(16); log('teleport: saved "'+t[2]+'" @ '+cx.toFixed(1)+','+cy.toFixed(1)+','+cz.toFixed(1)); return; }
            if(!sub){ log('current: x='+cx.toFixed(2)+' y='+cy.toFixed(2)+' z='+cz.toFixed(2)+'  | saved: ['+(Object.keys(tpMarks).join(', ')||'none')+']  | use: teleport <x> <y> <z> | teleport save <name> | teleport <name>'); return; }
            const dst=Memory.alloc(16); Memory.copy(dst,cur,16);   // base on current (preserves w)
            if(!isNaN(parseFloat(sub)) && t.length>=4){ dst.writeFloat(parseFloat(t[1])); dst.add(4).writeFloat(parseFloat(t[2])); dst.add(8).writeFloat(parseFloat(t[3])); }
            else if(tpMarks[sub]){ dst.writeByteArray(tpMarks[sub]); }
            else { log('teleport: "'+sub+'" is not coords or a saved name (try: teleport save '+sub+')'); return; }
            const fac=getViaGetter(gi,'GetTeleportationFacility'); if(!fac){ log('teleport: GetTeleportationFacility not reachable'); return; }
            const tp=resolveAny(['gameTeleportationFacility'],'Teleport'); if(!tp){ log('teleport: Teleport not found'); return; }
            const rot=Memory.alloc(16); rot.writeU64(0); rot.add(8).writeU64(0);   // EulerAngles 0,0,0
            try{ callFunc(tp.fn, fac, tp.retType, ['@'+p, {raw:dst,n:16}, {raw:rot,n:12}]);
                log('*** teleported to '+dst.readFloat().toFixed(1)+','+dst.add(4).readFloat().toFixed(1)+','+dst.add(8).readFloat().toFixed(1)+' ***'); }
            catch(e){ log('teleport err: '+e); }
        }
        // get a system from the scriptable container OR via a static GameInstance.GetXxx(gi) getter
        function getSystemFlexible(gi, scriptName, getterName){
            let s=getScriptableSystem(gi, scriptName); if(s) return s;
            if(getterName){ s=getViaGetter(gi, getterName); if(s) return s; }
            return null;
        }
        function doRemove(name,qty){
            const e=resolveFunc('gameTransactionSystem','RemoveItem'); if(!e){ log('RemoveItem not found'); return; }
            const tx=instOf('gameTransactionSystem'); if(!tx){ log('no transaction system instance yet'); return; }
            const id=Memory.alloc(16); id.writeU64(0); id.add(8).writeU64(0); fromTDBID(tdbidBytes(name),id);
            try{ const r=callFuncRaw(e.fn, tx, e.retType, [{kind:'handle',inst:authPlayer()},{kind:'item16',ptr:id},{kind:'i32',v:qty}]);
                const ok=r.readU8(); log('remove '+name+' x'+qty+' -> '+ok); if(!ok) log('  (not removed - bad item id, or you don\'t have it; names start with "Items.")'); }catch(ex){ log('remove err: '+ex); }
        }
        function doSetFact(name, val){
            const gi=getGI(); if(!gi){ log('setfact: no GameInstance'); return; }
            const qs=getSystemFlexible(gi,'questQuestsSystem','GetQuestsSystem'); if(!qs){ log('setfact: QuestsSystem not reachable'); return; }
            const e=resolveAny(['questQuestsSystem'],'SetFact'); if(!e){ log('setfact: SetFact not found'); return; }
            try{ callFunc(e.fn, qs, e.retType, [name, ''+val]); log('*** setfact '+name+' = '+val+' ***'); }catch(ex){ log('setfact err: '+ex); }
        }
        function doHeal(){
            const gi=getGI(); if(!gi){ log('heal: no GameInstance'); return; }
            const sps=getSystemFlexible(gi,'gameStatPoolsSystem','GetStatPoolsSystem'); if(!sps){ log('heal: StatPoolsSystem not reachable'); return; }
            const p=authPlayer(gi); if(!p){ log('heal: no player'); return; }
            const geid=resolveAny(['gameObject','gameEntity'],'GetEntityID'); if(!geid){ log('heal: GetEntityID not found'); return; }
            const eid=callFunc(geid.fn,p,geid.retType,[]);
            const rs=resolveAny(['gameStatPoolsSystem'],'RequestSettingStatPoolValue'); if(!rs){ log('heal: RequestSettingStatPoolValue not found'); return; }
            // (gameStatsObjectID, gamedataStatPoolType 'Health', Float value, source(null), Bool, Bool)
            // The pool value is ABSOLUTE points (~1816 at high levels), not a 0-100 percentage, so 100
            // under-heals badly. Set a value far above any max; the pool clamps it to the real max (full).
            const src=Memory.alloc(16);   // zeroed null source
            try{ callFunc(rs.fn, sps, rs.retType, [{raw:eid,n:8},'Health','1000000',{raw:src,n:16},'false','false']); log('*** heal: Health set to full ***'); }
            catch(e){ log('heal err: '+e); }
        }
        function doSummon(){
            const gi=getGI(); if(!gi){ log('summon: no GameInstance'); return; }
            const vs=getSystemFlexible(gi,'gameVehicleSystem','GetVehicleSystem'); if(!vs){ log('summon: VehicleSystem not reachable'); return; }
            const e=resolveAny(['gameVehicleSystem'],'ToggleSummonMode'); if(!e){ log('summon: ToggleSummonMode not found'); return; }
            try{ callFunc(e.fn, vs, e.retType, []); log('*** toggled vehicle summon mode ***'); }catch(ex){ log('summon err: '+ex); }
        }
        // read-only recon: logs exact signatures for the commands still to build (inventory/stats/facts/world)
        function convdump(){ log('=== CONVDUMP ===');
            probeFuncs('gameIQuestsSystem',['SetFact','GetFact','SetFactStr']);
            probeFuncs('questQuestsSystem',['SetFact','GetFact']);
            probeFuncs('EquipmentSystem',['EquipItem','UnequipItem']);
            probeFuncs('EquipmentSystemPlayerData',['EquipItem','UnequipItem','EquipItemInSlot']);
            probeFuncs('gamePlayerSystem',['GetLocalPlayerControlledGameObject','GetLocalPlayerMainGameObject','GetLocalPlayer','GetPlayerControlledGameObject','GetPlayer']);
            probeFuncs('gameTransactionSystem',['GiveItem','RemoveItem','HasItem','RemoveItemFromInventory','GetItemQuantity']);
            probeFuncs('gameEquipmentSystem',['EquipItem','UnequipItem','GetItemInEquipSlot']);
            probeFuncs('gameStatsSystem',['GetStatValue','GetStatBonusMultiplier']);
            probeFuncs('gameStatPoolsSystem',['GetStatPoolValue','RequestSettingStatPoolMinValue','RequestChangingStatPoolValue','RequestSettingStatPoolValue']);
            probeFuncs('QuestsSystem',['SetFact','GetFact','SetFactStr']);
            probeFuncs('gameVehicleSystem',['TogglePlayerActiveVehicle','EnablePlayerVehicle','SpawnPlayerVehicle','ToggleSummonMode']);
            probeFuncs('gameGodModeSystem',['AddGodMode','RemoveGodMode','HasGodMode']);
            probeFuncs('PlayerDevelopmentData',['AddExperience','SetLevel','GetProficiencyLevel']);
            try{ const p=curPlayer(); const gw=resolveAny(['gameObject','gameEntity'],'GetWorldPosition');
                if(gw&&p){ const r=callFunc(gw.fn,p,gw.retType,[]); log('  player WorldPosition(16B)='+hexp(r,16)); } }catch(e){ log('  pos err: '+e); }
        }
        function addPoints(n, member){
            const devData=getDevData(); if(!devData){ return; }
            const adp=resolveFunc('PlayerDevelopmentData','AddDevelopmentPoints'); if(!adp){ log('AddDevelopmentPoints not found'); return; }
            log('  AddDevelopmentPoints '+sigStr(adp.fn));
            try{ callFunc(adp.fn, devData, adp.retType, [''+n, member]); log('*** '+member+' points +'+n+' DONE ***'); }
            catch(e){ log('AddDevelopmentPoints err: '+e); } }
        // ===== Phase 2 recon: identify the Metal present path (raw libobjc; Frida ObjC bridge is absent) =====
        let mrArmed=false, mrCap=false, _objc=null, _expCache={};
        function resolveExport(name){ if(_expCache[name]!==undefined) return _expCache[name]; let r=null;
            try{ if(typeof Module!=='undefined'){
                if(typeof Module.findExportByName==='function'){ const p=Module.findExportByName(null,name); if(p&&!p.isNull()) r=p; }
                if(!r&&typeof Module.getExportByName==='function'){ try{ const p=Module.getExportByName(null,name); if(p&&!p.isNull()) r=p; }catch(e){} }
            }}catch(e){}
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ try{ if(typeof m.findExportByName==='function'){ const p=m.findExportByName(name); if(p&&!p.isNull()){ r=p; break; } } }catch(e){} } }catch(e){} }
            if(!r){ try{ const mods=Process.enumerateModules(); for(const m of mods){ const mn=m.name||''; if(mn.indexOf('libobjc')<0&&mn.indexOf('libsystem')<0) continue; let exps=null; try{ exps=(typeof m.enumerateExports==='function')?m.enumerateExports():(typeof Module.enumerateExports==='function'?Module.enumerateExports(mn):null); }catch(e){}
                if(exps){ for(const e of exps){ if(e.name===name){ r=e.address; break; } } } if(r) break; } }catch(e){} }
            _expCache[name]=r; return r; }
        function objcRT(){ if(_objc) return _objc;
            const f=(n,r,a)=>{ const p=resolveExport(n); return p?new NativeFunction(p,r,a):null; };
            const o={ getClass:f('objc_getClass','pointer',['pointer']), selReg:f('sel_registerName','pointer',['pointer']),
                cgim:f('class_getInstanceMethod','pointer',['pointer','pointer']), mgi:f('method_getImplementation','pointer',['pointer']),
                copyList:f('objc_copyClassList','pointer',['pointer']), cname:f('class_getName','pointer',['pointer']),
                msgP:f('objc_msgSend','pointer',['pointer','pointer']), msgU:f('objc_msgSend','uint64',['pointer','pointer']),
                msgB:f('objc_msgSend','bool',['pointer','pointer']) };
            o.cls=(n)=>o.getClass(Memory.allocUtf8String(n)); o.sel=(n)=>o.selReg(Memory.allocUtf8String(n));
            _objc=o; return o; }
        function metalRecon(){
            log('METALRECON: api Module.findExportByName='+(typeof Module!=='undefined'&&typeof Module.findExportByName)+' Module.enumerateExports='+(typeof Module!=='undefined'&&typeof Module.enumerateExports)+' Process.enumerateModules='+(typeof Process!=='undefined'&&typeof Process.enumerateModules));
            const o=objcRT();
            if(!o.getClass||!o.msgP){ log('METALRECON: libobjc exports unresolved (objc_getClass='+(resolveExport('objc_getClass')||'null')+' objc_msgSend='+(resolveExport('objc_msgSend')||'null')+')'); return; }
            log('METALRECON: libobjc OK. CAMetalLayer='+(!o.cls('CAMetalLayer').isNull())+' MTLCreateSystemDefaultDevice='+(!!resolveExport('MTLCreateSystemDefaultDevice')));
            // Enumerate command-buffer classes that respond to presentDrawable: (candidate present-hook points)
            try{ const cnt=Memory.alloc(4); const arr=o.copyList(cnt); const n=cnt.readU32(); const psel=o.sel('presentDrawable:'); let hits=[];
                for(let i=0;i<n && hits.length<24;i++){ const c=arr.add(i*8).readPointer(); if(c.isNull()) continue; let nm=''; try{ nm=o.cname(c).readUtf8String(); }catch(e){ continue; }
                    if(nm && nm.indexOf('CommandBuffer')>=0){ const m=o.cgim(c, psel); if(!m.isNull()) hits.push(nm); } }
                log('METALRECON: CommandBuffer classes (count '+n+' total) w/ presentDrawable:: '+(hits.join(', ')||'(none)')); }
            catch(e){ log('METALRECON: class enum err: '+e); }
            // One-shot hook on -[CAMetalLayer nextDrawable] IMP to capture layer device/format/size + drawable texture
            if(mrArmed){ log('METALRECON: already armed (cap='+mrCap+')'); return; }
            try{ const cm=o.cls('CAMetalLayer'); if(cm.isNull()){ log('METALRECON: CAMetalLayer class not found'); return; }
                const meth=o.cgim(cm, o.sel('nextDrawable')); if(meth.isNull()){ log('METALRECON: nextDrawable method not found'); return; }
                const imp=o.mgi(meth); log('METALRECON: nextDrawable IMP='+imp);
                const sDev=o.sel('device'), sPix=o.sel('pixelFormat'), sFb=o.sel('framebufferOnly'), sTex=o.sel('texture'),
                      sW=o.sel('width'), sH=o.sel('height'), sName=o.sel('name'), sUtf=o.sel('UTF8String');
                Interceptor.attach(imp, {
                    onEnter:function(a){ this.self=a[0]; },
                    onLeave:function(ret){ if(mrCap) return; mrCap=true;
                        try{ const layer=this.self; const dev=o.msgP(layer,sDev); let devName='?'; try{ const ns=o.msgP(dev,sName); const cs=o.msgP(ns,sUtf); devName=cs.readUtf8String(); }catch(e){}
                            log('METALRECON FRAME: layer='+layer+' device='+dev+'('+devName+') pixelFormat='+o.msgU(layer,sPix).toString()+' framebufferOnly='+o.msgB(layer,sFb));
                            if(!ret.isNull()){ const tex=o.msgP(ret,sTex); log('METALRECON FRAME: drawable='+ret+' tex='+tex+' tex.pixelFormat='+o.msgU(tex,sPix).toString()+' '+o.msgU(tex,sW).toString()+'x'+o.msgU(tex,sH).toString()); }
                        }catch(e){ log('METALRECON FRAME cap err: '+e); } }
                });
                mrArmed=true; log('METALRECON: nextDrawable hook armed - capturing next frame');
            }catch(e){ log('METALRECON: hook err: '+e); }
        }
        // Translate common CET copy-paste one-liners into our commands (so internet snippets paste directly).
        function cetTranslate(line){ let m;
            // Game.AddToInventory("Items.X" [, qty])   -- by far the most copy-pasted CET call
            m=line.match(/^Game\.AddToInventory\(\s*['"]([A-Za-z0-9_.]+)['"]\s*(?:,\s*([0-9]+))?\s*\)\s*;?\s*$/);
            if(m) return 'give '+m[1]+' '+(m[2]||'1');
            return null; }
        function execute(line){ let raw=line.trim();
            const ct=cetTranslate(raw); if(ct){ log('(cet) '+raw+'  ->  '+ct); raw=ct; }
            const t=raw.split(/\s+/);
            if(t[0]==='metalrecon'){ metalRecon(); return; }   // Phase-2 recon: works at menu too
            if(t[0]==='tweakload'){ try{ var ex=resolveExport('cybermodman_tweakReload'); if(!ex||ex.isNull()){ log('tweakload: cybermodman_tweakReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('tweakload: cybermodman_tweakReload() called - check TweakXL.log'); }catch(e){ log('tweakload err '+e); } return; }   // exempt from in-game guard (drives TweakXL apply)
            if(t[0]==='tweakdumpflat'&&t[1]&&t[2]){ try{ var ex=resolveExport('cybermodman_tweakDumpFlat'); if(!ex||ex.isNull()){ log('tweakdumpflat: export NOT FOUND'); return; } var sr=Memory.allocUtf8String(t[1]); var spp=Memory.allocUtf8String(t[2]); new NativeFunction(ex,'void',['pointer','pointer'])(sr,spp); log('tweakdumpflat: '+t[1]+'.'+t[2]+' -> /tmp/tweakxl_dump.txt'); }catch(e){ log('tweakdumpflat err '+e); } return; }   // dump ONE flat by exact <Record> <prop>
            if(t[0]==='cmnreload'){ try{ var n=cmnLoad(); log('cmnreload: loaded '+n+' custom name(s); see /tmp/cybermodman_names.log'); }catch(e){ log('cmnreload err '+e); } return; }   // hot-reload cybermodman_names.json
            if(t[0]==='archiveload'){ try{ var ex=resolveExport('cybermodman_archiveReload'); if(!ex||ex.isNull()){ log('archiveload: cybermodman_archiveReload export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveload: cybermodman_archiveReload() called - check ArchiveXL.log'); }catch(e){ log('archiveload err '+e); } return; }   // drives ArchiveXL extension bring-up
            if(t[0]==='archiveprobe'){ try{ var ex=resolveExport('cybermodman_archiveProbeLoadTexts'); if(!ex||ex.isNull()){ log('archiveprobe: cybermodman_archiveProbeLoadTexts export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveprobe: cybermodman_archiveProbeLoadTexts() called - check ArchiveXL.log'); }catch(e){ log('archiveprobe err '+e); } return; }   // wall-B probe: drive LoadTexts directly
            if(t[0]==='archiveinject'){ try{ var ex=resolveExport('cybermodman_archiveInjectName'); if(!ex||ex.isNull()){ log('archiveinject: cybermodman_archiveInjectName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archiveinject: cybermodman_archiveInjectName() called - check ArchiveXL.log'); }catch(e){ log('archiveinject err '+e); } return; }   // wall-B exp: overwrite live onscreens text
            if(t[0]==='archivehookname'){ try{ var ex=resolveExport('cybermodman_archiveHookName'); if(!ex||ex.isNull()){ log('archivehookname: cybermodman_archiveHookName export NOT FOUND'); return; } new NativeFunction(ex,'void',[])(); log('archivehookname: cybermodman_archiveHookName() called - check ArchiveXL.log'); }catch(e){ log('archivehookname err '+e); } return; }   // wall-B exp: hook item display-name resolver
            if(t[0]==='archivename'){ try{ if(nameHookInstalled){ log('archivename: already installed'); return; } var naddr=base.add(0x378a4b8); var ncalls=0; Interceptor.attach(naddr,{ onEnter:function(a){ this.sret=this.context.x8; }, onLeave:function(r){ try{ var b=this.sret; if(!b||b.isNull()) return; var len=b.add(0x14).readU32(); var heap=(len&0x40000000)!==0; var alen=len&0x3FFFFFFF; var tp=heap?b.readPointer():b; var txt=''; try{ txt=tp.readUtf8String(alen); }catch(e){} if(ncalls<25){ ncalls++; log('namehook #'+ncalls+' x8='+b+' len='+alen+' heap='+heap+' text="'+txt+'"'); } if(txt && txt.indexOf('exington')>=0){ var s='CyberModMan!'; b.writeUtf8String(s); b.add(0x14).writeU32(s.length); b.add(0x18).writePointer(ptr(0)); log('namehook OVERWROTE "'+txt+'" -> '+s); } }catch(e){ log('namehook onLeave err '+e); } } }); nameHookInstalled=true; log('archivename: Frida interceptor attached at '+naddr+' (open inventory, hover a Lexington)'); }catch(e){ log('archivename err '+e); } return; }   // wall-B: DIRECT Frida interceptor on item name resolver (RED4ext plugin hooks dont fire)
            if(t[0]==='observe'){   // live-register an Observe (works pre-game: settings/main-menu controllers fire here)
                if(t[1]==='off'||t[1]==='clear'){ cmUnobserve(); return; }
                if(t[1]==='list'){ let parts=[]; for(const k in obsByMethod){ for(let i=0;i<obsByMethod[k].length;i++){ const ob=obsByMethod[k][i]; parts.push(ob.className+'.'+ob.methodName+'('+ob.hits+')'); } } log('observe list ['+obsCount+']: '+(parts.join(', ')||'(none)')); return; }
                if(t[1]&&t[2]){ cmObserve(t[1], t[2], null); return; }   // observe <Class> <Method>
                if(t[1]){ cmObserve(null, t[1], null); return; }         // observe <Method>  (matches on any class)
                log('usage: observe <Class> <Method> | observe <Method> | observe list | observe off'); return; }
            if(t[0]==='mkobj'&&t[1]){ try{ const inst=createInstance(t[1]); if(!inst){ log('mkobj '+t[1]+' -> NULL (class unknown or alloc failed)'); return; }
                let dump=''; try{ dump=hexp(inst,0x40); }catch(e){ dump='(read err)'; }
                log('mkobj '+t[1]+' -> '+inst); log('   [0x40]='+dump); }catch(e){ log('mkobj err '+e); } return; }   // create a script object via AllocMemory+ConstructCls
            if(t[0]==='field'&&t[1]&&t[2]){ try{ const f=findProp(t[1],t[2]); if(!f){ log('field '+t[1]+'.'+t[2]+' NOT FOUND'); return; } log('field '+t[1]+'.'+t[2]+' -> offset 0x'+f.off.toString(16)+'  type '+f.typeName); }catch(e){ log('field err '+e); } return; }   // resolve a field offset+type (read-only)
            if(t[0]==='props'&&t[1]){ try{ let cls=clsByName(t[1]); if(!cls){ log('props: class '+t[1]+' UNKNOWN'); return; } let out=[], guard=0;
                while(cls&&!cls.isNull()&&guard++<12){ const pp=cls.add(0x28).readPointer(), n=cls.add(0x30).readU32();
                    for(let i=0;i<n&&out.length<60;i++){ const pr=pp.add(i*8).readPointer(); if(pr.isNull())continue; const nh='0x'+pr.add(0x08).readU64().toString(16); const off=pr.add(0x20).readU32(); let tn='?'; try{tn=nameOf(pr.readPointer());}catch(e){} out.push(nh+'@0x'+off.toString(16)+':'+tn); }
                    cls=cls.add(0x10).readPointer(); }
                log('props '+t[1]+' ['+out.length+']:'); for(let i=0;i<out.length;i+=3) log('   '+out.slice(i,i+3).join('   ')); }catch(e){ log('props err '+e); } return; }   // list class fields (read-only; names are hashes)
            if(t[0]==='mkmods'){ try{ const inst=createInstance('PauseMenuListItemData'); if(!inst){ log('mkmods: create failed'); return; }
                try{ inst.writeUtf8String('Mods'); inst.add(0x14).writeU32(4); inst.add(0x18).writePointer(ptr(0)); }catch(e){ log('  label err '+e); }   // label @0x00 String (inline)
                try{ inst.add(0x20).writeU64(u64(fnv('OnSwitchToSettings'))); }catch(e){ log('  eventName err '+e); }                                  // eventName @0x20 CName
                try{ let ev=resolveEnumByTypeHash('0x'+fnv('PauseMenuAction').toString(16),'OpenSubMenu'); if(ev===null){ log('  action: OpenSubMenu enum not resolved'); } else { inst.add(0x28).writeU32(ev.toNumber()>>>0); log('  action OpenSubMenu = '+ev); } }catch(e){ log('  action err '+e); }   // action @0x28 PauseMenuAction
                let dump=''; try{ dump=hexp(inst,0x40); }catch(e){} log('mkmods -> '+inst+'  (label="Mods" eventName=OnSwitchToSettings)'); log('   [0x40]='+dump); }catch(e){ log('mkmods err '+e); } return; }   // build+fill a Mods menu-item (no PushData yet)
            if(t[0]==='modsbutton'){ if(t[1]==='off'){ cmUnobserve(); log('modsbutton: cleared'); return; }
                const sigOf=function(fn){ try{ const pe=fn.add(0x28).readPointer(),pc=fn.add(0x30).readU32();let p=[];for(let i=0;i<pc;i++){try{p.push(nameOf(pe.add(i*8).readPointer().readPointer()));}catch(e){p.push('?');}}return 'params['+pc+']=['+p.join(', ')+']'; }catch(e){ return 'sigErr'; } };
                try{ const pdc=resolveFunc('inkListController','PushData'); log('modsbutton: inkListController.PushData = '+(pdc?(sigOf(pdc.fn)+' ret='+(pdc.retType.isNull()?'void':nameOf(pdc.retType))):'NOT FOUND')); }catch(e){ log('modsbutton: PushData resolve err '+e); }
                let shown=0;
                cmObserve('gameuiMenuItemListGameController','AddMenuItem', function(ctx){ try{ if(shown>=12) return;
                    const mlc=ctx.add(0x38).readPointer(); let vt=ptr(0); try{ vt=mlc.readPointer(); }catch(e){}
                    if(!vt.isNull()){ shown++; const mm=instType(mlc); const cm=instType(ctx); log('modsbutton: VALID mlc='+mlc+' class='+(mm?nameOf(mm):'?')+'  (ctx class '+(cm?nameOf(cm):'?')+')'); }
                }catch(e){ log('modsbutton cb err '+e); } });
                log('modsbutton: armed (read-only sig capture). Open a menu so AddMenuItem fires; "modsbutton off" clears.'); return; }   // capture PushData contract before we call it
            if(!player){ log('NOT IN GAME yet: '+line); return; }
            if(t[0]==='give'&&t[1]){ doGive(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='money'&&t[1]){ doGive('Items.money', Math.max(1,parseInt(t[1])||1), true); return; }   // currency: always one bulk add
            if(t[0]==='perks'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Primary'); return; }
            if(t[0]==='attrs'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Attribute'); return; }
            if(t[0]==='relic'&&t[1]){ addPoints(Math.max(1,parseInt(t[1])||1),'Espionage'); return; }
            if(t[0]==='godmode'){ doGodmode(t[1]!=='off'); return; }
            if(t[0]==='invis'||t[0]==='invisible'){ doInvisible(t[1]!=='off'); return; }
            if(t[0]==='infammo'||t[0]==='ammo'){ doInfammo(t[1]!=='off'); return; }
            if(t[0]==='time'&&t[1]){ doTime(Math.max(0,Math.min(23,parseInt(t[1])||0)), Math.max(0,Math.min(59,parseInt(t[2]||'0')||0))); return; }
            if(t[0]==='slowmo'){ if(t[1]==='off') doSlowmo(false); else doSlowmo(true, parseFloat(t[1])||0.3); return; }
            if(t[0]==='nopolice'||t[0]==='police'){ doNoPolice(t[1]!=='off'); return; }
            if((t[0]==='removeitem'||t[0]==='remove')&&t[1]){ doRemove(t[1], Math.max(1,parseInt(t[2]||'1')||1)); return; }
            if(t[0]==='heal'){ doHeal(); return; }
            if((t[0]==='setfact'||t[0]==='addfact')&&t[1]){ doSetFact(t[1], parseInt(t[2]||'1')||1); return; }
            if(t[0]==='summon'||t[0]==='car'){ doSummon(); return; }
            if(t[0]==='level'&&t[1]){ doLevel(Math.max(1,parseInt(t[1])||1)); return; }
            if((t[0]==='streetcred'||t[0]==='sc')&&t[1]){ doStreetCred(Math.max(1,Math.min(50,parseInt(t[1])||1))); return; }
            if(t[0]==='teleport'||t[0]==='tp'){ doTeleport(t); return; }
            if(t[0]==='convdump'){ convdump(); return; }
            if(t[0]==='devdump'){ probeFuncs('PlayerDevelopmentSystem',['GetData','GetDevelopmentData','GetDevelopmentDataInternal','GetInstance']);
                probeFuncs('PlayerDevelopmentData',['AddDevelopmentPoints']); return; }
            if(t[0]==='call'&&t[2]){ const cls=t[1],method=t[2],args=t.slice(3); const e=resolveFunc(cls,method); if(!e){ log('method '+cls+'.'+method+' not found'); return; }
                let ctx=instOf(cls); if(args[0]==='@self'){} if(!ctx) ctx=player;
                try{ const r=callFunc(e.fn, ctx, e.retType, args); log('call '+cls+'.'+method+'('+args.join(',')+') -> '+r.readU64()); }catch(ex){ log('call err: '+ex); } return; }
            if(t[0]==='sig'&&t[2]){ const e=resolveFunc(t[1],t[2]); if(!e){ log('sig '+t[1]+'.'+t[2]+' NOT FOUND'); return; }
                const pe=e.fn.add(0x28).readPointer(), pc=e.fn.add(0x30).readU32(); let parts=[];
                for(let i=0;i<pc;i++){ const pr=pe.add(i*8).readPointer(); parts.push(nameOf(pr.readPointer())); }
                log('sig '+t[1]+'.'+t[2]+': params['+pc+']=['+parts.join(', ')+'] ret='+(e.retType.isNull()?'void':nameOf(e.retType))); return; }
            if(t[0]==='findinst'&&t[1]){ const m=clsByName(t[1]); if(!m){ log('findinst: class '+t[1]+' UNKNOWN'); return; }
                const inst=instReg[m.sub(base).add(FV0).toString(16)]; log('findinst '+t[1]+' -> '+(inst?inst:'NONE captured')); return; }
            log('unknown: '+line); }
        setInterval(function(){ try{ const c=readFile(CMD); const s=(c||'').trim();
            if(!s){ lastCmd=''; return; }                 // file empty -> re-arm so an identical next command fires again
            if(s!==lastCmd){ lastCmd=s; const cmd=s.replace(/^\d+\t/,''); pendingQ.push(cmd); clearFile(CMD); log('queued: '+cmd); } }catch(e){} }, 120);
        // Clean shutdown: the game's static-destructor teardown segfaults with hooks attached (cosmetic,
        // happens AFTER the game has saved + quit). Route exit() -> _exit() to skip that teardown so the
        // process exits cleanly (no macOS crash dialog, exit code 0).
        try{ const eP=resolveExport('exit'), xP=resolveExport('_exit');
            if(eP&&xP){ const _x=new NativeFunction(xP,'void',['int']);
                Interceptor.replace(eP, new NativeCallback(function(c){ _x(c); }, 'void', ['int']));
                log('clean-exit installed'); }
            else log('clean-exit: exit/_exit not resolved'); }catch(e){ log('clean-exit err: '+e); }
        // The real shutdown crash is in the game's own teardown (a stale hook/trampoline call), which runs
        // AFTER the save is flushed but BEFORE exit(). So when Main() returns (game quitting, save done),
        // _exit(0) immediately - we never reach the crashing teardown. (Main is at base+0x31e18 on 2.3.1.)
        try{ const xP2=resolveExport('_exit');
            if(xP2){ const _x2=new NativeFunction(xP2,'void',['int']);
                Interceptor.attach(base.add(0x31e18), { onLeave:function(){ try{ clearFile(CMD); }catch(e){} _x2(0); } });
                log('shutdown-exit hook installed (Main+0x31e18)'); }
            else log('shutdown-exit: _exit unresolved'); }catch(e){ log('shutdown-exit err: '+e); }
        log('==== MINI-CET v3 (universal call + perks/attrs/relic) ready ====');
        Interceptor.attach(execAddr,{
            onEnter:function(args){ depth++; if(busy) return;
                try{ const fn=args[0],ctx=args[1]; if(fn.isNull()||ctx.isNull()) return;
                    if(!fromtd){ const nm='0x'+fn.add(0x08).readU64().toString(16); if(nm==='0x150155547ef75590'){ const rp=fn.add(0x18).readPointer(); fromtd={fn:fn,ctx:ctx,retType:rp.isNull()?ptr(0):rp.readPointer()}; } }
                    const vt=ctx.readPointer(); if(vt.isNull()) return;
                    // Observe dispatch (zero cost when no observers registered). Must run BEFORE the
                    // player/seenVt early-returns below, or observers would fire at most once per vtable.
                    if(obsCount){ const omh='0x'+fn.add(0x10).readU64().toString(16); const olist=obsByMethod[omh];
                        if(olist){ let cmeta=null; try{ cmeta=new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(ctx); }catch(e){}
                            for(let oi=0;oi<olist.length;oi++){ const ob=olist[oi]; if(ob.classHash && (cmeta===null || !classIsA(cmeta, ob.classHash))) continue; obsFire(ob, ctx, args[2], fn); } } }
                    if(playerVt && vt.equals(playerVt)){ player=ctx; addCand(ctx); return; }
                    const vk=vt.toString(); if(seenVt.has(vk)) return; seenVt.add(vk);
                    const fn0=vt.readPointer(); if(fn0.isNull()) return;
                    const meta=new NativeFunction(vt.add(8).readPointer(),'pointer',['pointer'])(ctx);  // GetType -> CClass
                    if(meta.isNull()) return; const fv=meta.sub(base).add(FV0).toString(16); instReg[fv]=ctx;
                    if(nameOf(meta)===PLAYER){ playerVt=vt; player=ctx; addCand(ctx); }
                }catch(e){} },
            onLeave:function(r){ depth--; if(busy) return; if(pendingQ.length&&depth===0){ const cmd=pendingQ.shift(); busy=true; try{ execute(cmd); }catch(e){ log('exec err '+e); } busy=false; } }
        });
    }catch(e){ log('MINI-CET v3 FAILED: '+e); }

// ===== cybermodman cmn loc-hook (re-merged after CET update) =====
var cmnB = getModuleBase();
var CMN_CONFIG = '/Users/ysr/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/cybermodman_names.json';
var CMN_LOG = '/tmp/cybermodman_names.log';
var cmnMap = {};
var cmnHit = {}; // cybermodman: runtime fill hit-counter per LocKey (throttled logging)
var cmnStrCache = {}; // text -> persistent Frida buffer (kept alive; reused)
var cmnBase = null;
var cmnReserve = null;   // NativeFunction(FUN_10002c904): grows a CString to a game-pool heap buffer
var cmnAttached = false;
function cmnLog(s){ try{ var f=new File(CMN_LOG,'a'); f.write(s+'\n'); f.flush(); f.close(); }catch(e){} try{ console.log('[CMN] '+s); }catch(e2){} }
function cmnLoad(){
    cmnMap = {}; var n = 0;
    try {
        var txt = File.readAllText(CMN_CONFIG);
        if (!txt) { cmnLog('no config file at '+CMN_CONFIG); return 0; }
        var obj = JSON.parse(txt);
        for (var k in obj) {
            if (!obj.hasOwnProperty(k)) continue;
            var radix = (k.indexOf('0x')===0 || k.indexOf('0X')===0) ? 16 : 10;
            var kp = parseInt(k, radix);
            if (isNaN(kp)) { cmnLog('  skip non-numeric key "'+k+'"'); continue; }
            var ki = kp >>> 0;
            cmnMap[ki] = String(obj[k]);
            n++;
            cmnLog('  map LocKey '+ki+' (0x'+ki.toString(16)+') -> "'+cmnMap[ki]+'"');
        }
        cmnLog('loaded '+n+' custom name(s)');
    } catch (e) { cmnLog('config error: '+e); }
    return n;
}
// Write a CString into the engine's output buffer at b. Short strings go inline (proven path).
// Long strings use a persistent buffer + the 0x80000000 'not-owned' flag so the engine reads the
// text but its destructor SKIPS free (verified: dtor frees only when (length>>30)!=2). No allocator
// mismatch, any length safe. (CString: ptr/inline @0x00, capacity @0x10, length+flags @0x14.)
function cmnPutStr(b, s){
    if (s.length < 0x14) {                         // short -> inline (proven)
        b.writeUtf8String(s);
        b.add(0x14).writeU32(s.length);
        b.add(0x18).writePointer(ptr(0));
        return;
    }
    // long -> game-allocated heap CString so the engine both READS (0x40000000) and FREES it safely
    // (FUN_10002c904 allocs from the PoolString pool when allocator@0x18==0; the dtor frees via the
    // same pool). We zero @0x18 first, grow, then write our text into the returned game buffer.
    try {
        if (cmnReserve) {
            b.add(0x18).writePointer(ptr(0));       // default pool allocator
            cmnReserve(b, s.length);                // alloc -> ptr@0x00, capacity@0x10, len|0x40000000
            var p = b.readPointer();
            if (p && !p.isNull()) {
                p.writeUtf8String(s);               // write text into game buffer
                b.add(0x14).writeU32((s.length & 0x3FFFFFFF) | 0x40000000);
                return;
            }
        }
    } catch (e) { try { cmnLog('reserve err: '+e); } catch (_) {} }
    var t = s.substr(0, 19);                        // fallback: inline-truncate (never blank/crash)
    b.writeUtf8String(t);
    b.add(0x14).writeU32(t.length);
    b.add(0x18).writePointer(ptr(0));
}
function cmnInstall(){
    if (cmnAttached) return;
    var cmnB = getModuleBase();
    if (!cmnB) { cmnLog('module cmnB not found; cannot install'); return; }
    cmnBase = cmnB;
    try { cmnReserve = new NativeFunction(cmnB.add(0x2c904), 'void', ['pointer','uint']); } catch (e) { cmnLog('reserve fn err: '+e); }
    var addr = cmnB.add(0x2f6ea14); // FUN_102f6ea14 loc-map lookup: out=x8, key=x1, &found=x3
    try {
        Interceptor.attach(addr, {
            onEnter: function (a) { this.out = this.context.x8; this.k1 = this.context.x1; this.fp = this.context.x3; },
            onLeave: function (r) {
                try {
                    if (!this.k1) return;
                    var name = cmnMap[this.k1.toUInt32() >>> 0];
                    if (name === undefined) return;
                    var __k = this.k1.toUInt32() >>> 0;
                    if (cmnHit[__k] === undefined) cmnHit[__k] = 0;
                    if (cmnHit[__k]++ < 4) cmnLog('HIT key='+__k+' (0x'+__k.toString(16)+') fill="'+String(name).substring(0,48)+'"');
                    var b = this.out; if (!b || b.isNull()) return;
                    cmnPutStr(b, name); // inline (short) or not-owned persistent buffer (long)
                    if (this.fp && !this.fp.isNull()) { try { this.fp.writeU8(1); } catch (e) {} } // force found=1
                } catch (e) {}
            }
        });
        cmnAttached = true;
        cmnLog('interceptor attached at '+addr+' (FUN_102f6ea14)');
    } catch (e) { cmnLog('attach error: '+e); }
}
try { cmnLog('=== cybermodman custom-names init ==='); cmnLoad(); cmnInstall(); } catch (e) { try { console.log('[CMN] init err '+e); } catch (_) {} }

})();
