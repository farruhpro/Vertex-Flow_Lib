/*
    Vertex Flow transactional bridge for 3ds Max.
    Developer source format: .ms. Public release format: encrypted .mse created
    from this self-contained source with the standard MAXScript encryptScript().

    This bridge never saves the scene, copies textures, archives a project,
    changes project paths or performs a global material/Asset Tracking rewrite.

    [УДАЛЕНО]: Drag&Drop self-installer через getSourceFileName/copyFile — он
    зависел от открытого .ms, раскрывал исходник и ломал запуск клиентского .mse.
    [УДАЛЕНО]: getClassInstances processAllAnimatables/freeSceneBitmaps — глобальный
    обход и сброс могли менять/выгружать ресурсы существующей сцены.
    [УДАЛЕНО]: python.Execute с бинарным чтением .max для угадывания версии — это
    недокументированный хак; штатный importer теперь возвращает честную ошибку.
*/

global VertexFlow_Timer
global VertexFlow_Busy = false
global VertexFlow_Listening = true
global VertexFlow_Log = #()
global VertexFlow_UpdateUI
global VertexFlow_LastErrorCode = "ERR_MAX_INTERNAL"
global VertexFlow_ProcessedJobs = #()
global VertexFlow_JSONSerializer

-- Timer вызывает функции уже после завершения fileIn/.ms.
-- Поэтому runtime-константы объявлены явно global, а не как недолговечные
-- top-level local: поведение исходного .ms и зашифрованного .mse совпадает.
global VF_MIN_MAX_MAJOR = 24000 -- 3ds Max 2022
global VF_MAX_TASK_BYTES = 4194304
global VF_MAX_TASK_AGE_MS = 600000L
-- sysInfo.tempdir — документированный системный Temp в MAXScript.
-- Path.Combine исключает ручную склейку разделителей и формирует тот же путь,
-- который использует Rust на Windows.
global VF_TASK_FILE = (dotNetClass "System.IO.Path").Combine sysInfo.tempdir "vertex_flow_task.json"
global VF_FILE_PROPERTIES = #(
    #filename, #fileName, #file, #mapName, #HDRIMapName,
    #sourceFile, #sourceFilename, #textureFile, #bitmapFile,
    #ies_file, #iesFile
)

struct VFTask (
    jobId = "",
    modelPath = "",
    projectPath = "",
    texturesPath = "",
    status = "",
    relinkTextures = false
)

struct VFSceneSnapshot (
    nodes = #(),
    nodeHandles = #(),
    selectedNodes = #(),
    subObject = 0,
    nodeStates = #(),
    oldMaterials = #(),
    oldMaps = #(),
    mapPathStates = #(),
    layers = #(),
    environmentMapValue = undefined,
    backgroundColorValue = undefined,
    ambientColorValue = undefined,
    commandPanelMode = undefined
)

fn VertexFlow_LogMsg message level:"INFO" = (
    -- Одна диагностическая запись одновременно попадает в Listener
    -- и rollout; широкие catch() больше не скрывают производственные ошибки.
    local line = "[" + level + "] " + (message as string)
    format "[Vertex Flow] %\n" line
    insertItem line VertexFlow_Log 1
    if VertexFlow_Log.count > 50 do deleteItem VertexFlow_Log VertexFlow_Log.count
    if VertexFlow_UpdateUI != undefined do try(VertexFlow_UpdateUI())catch()
)

fn VF_Fail code message = (
    VertexFlow_LastErrorCode = code
    throw message
)

fn VF_JsonEscape value = (
    local result = value as string
    result = substituteString result "\\" "\\\\"
    result = substituteString result "\"" "\\\""
    result = substituteString result "\r" "\\r"
    result = substituteString result "\n" "\\n"
    result = substituteString result "\t" "\\t"
    result
)

fn VF_StringArrayJson values = (
    local result = "["
    for index = 1 to values.count do (
        if index > 1 do result += ","
        result += "\"" + VF_JsonEscape values[index] + "\""
    )
    result + "]"
)

fn VF_AtomicWrite text jobId = (
    -- .NET сначала пишет UTF-8 без BOM во временный файл рядом,
    -- затем File.Replace публикует его атомарно. Rust не увидит половину JSON.
    local safeId = substituteString (jobId as string) ":" "_"
    safeId = substituteString safeId "\\" "_"
    safeId = substituteString safeId "/" "_"
    local temporary = VF_TASK_FILE + "." + safeId + ".tmp"
    local backup = VF_TASK_FILE + "." + safeId + ".bak"
    local fileClass = dotNetClass "System.IO.File"
    local utf8 = dotNetObject "System.Text.UTF8Encoding" false
    try (
        if fileClass.Exists temporary do fileClass.Delete temporary
        if fileClass.Exists backup do fileClass.Delete backup
        fileClass.WriteAllText temporary text utf8
        -- Владение повторно проверяется непосредственно перед
        -- File.Replace. Это закрывает узкое окно гонки удаления/замены файла.
        if (VF_TaskFileBelongsToJob jobId) then (
            fileClass.Replace temporary VF_TASK_FILE backup true
            -- Удаление служебной backup-копии больше не определяет
            -- успех уже состоявшейся атомарной публикации. Раньше редкий сбой
            -- File.Delete после успешного File.Replace попадал во внешний catch:
            -- Rust мог увидеть terminal-ответ, а 3ds Max считал запись ошибочной
            -- и запускал rollback. Теперь backup очищается best-effort, а успех
            -- определяется исключительно результатом File.Replace.
            try(if fileClass.Exists backup do fileClass.Delete backup)catch()
            true
        ) else (
            if fileClass.Exists temporary do fileClass.Delete temporary
            false
        )
    ) catch (
        try(if fileClass.Exists temporary do fileClass.Delete temporary)catch()
        -- Неуспешный File.Replace также не оставляет служебную
        -- backup-копию. Она не участвует в протоколе и безопасно удаляется.
        try(if fileClass.Exists backup do fileClass.Delete backup)catch()
        false
    )
)

fn VF_WriteResult task status code message warnings:#() detailsJson:"{}" = (
    -- Перед каждым ответом мост проверяет, что общий task-файл
    -- всё ещё существует и принадлежит этому job_id. При закрытии Vertex Flow
    -- Rust удаляет задание; без этой проверки поздний completed/error заново
    -- создавал бы JSON и оставлял ложное «занятое» задание для следующего запуска.
    if not (VF_TaskFileBelongsToJob task.jobId) then (
        VertexFlow_LogMsg "TASK_CANCELLED: task file was removed or replaced" level:"WARNING"
        false
    ) else (
        local jobJson = "\"" + VF_JsonEscape task.jobId + "\""
        local codeJson = if code == undefined then "null" else ("\"" + VF_JsonEscape code + "\"")
        local payload = "{\"job_id\":" + jobJson
        payload += ",\"status\":\"" + VF_JsonEscape status + "\""
        payload += ",\"code\":" + codeJson
        payload += ",\"message\":\"" + VF_JsonEscape message + "\""
        payload += ",\"warnings\":" + VF_StringArrayJson warnings
        payload += ",\"details\":" + detailsJson + "}"
        if not (VF_AtomicWrite payload task.jobId) then (
            VertexFlow_LogMsg "ERR_RESULT_WRITE: cannot publish response" level:"ERROR"
            false
        ) else true
    )
)

fn VF_InitJson = (
    if VertexFlow_JSONSerializer != undefined then true
    else (
        -- JavaScriptSerializer — штатный .NET API, доступный через
        -- документированный dotNet interop MAXScript. Если API недоступен,
        -- задание отклоняется, а не разбирается самодельным парсером.
        try(dotNet.loadAssembly "System.Web.Extensions")catch()
        try(VertexFlow_JSONSerializer = dotNetObject "System.Web.Script.Serialization.JavaScriptSerializer")catch(VertexFlow_JSONSerializer = undefined)
        if VertexFlow_JSONSerializer != undefined do VertexFlow_JSONSerializer.MaxJsonLength = VF_MAX_TASK_BYTES
        VertexFlow_JSONSerializer != undefined
    )
)

fn VF_DictHas dictionary key = (
    try(dictionary.ContainsKey key)catch(false)
)

fn VF_DictGet dictionary key defaultValue = (
    if VF_DictHas dictionary key then try(dictionary.Item[key])catch(defaultValue) else defaultValue
)

fn VF_TryReadTaskJobId = (
    local fileClass = dotNetClass "System.IO.File"
    if not (fileClass.Exists VF_TASK_FILE) then undefined
    else if not (VF_InitJson()) then undefined
    else (
        local utf8 = dotNetObject "System.Text.UTF8Encoding" false
        local raw = try(fileClass.ReadAllText VF_TASK_FILE utf8)catch(undefined)
        if raw == undefined then undefined
        else (
            local root = try(VertexFlow_JSONSerializer.DeserializeObject raw)catch(undefined)
            if root == undefined then undefined
            else (
                local owner = VF_DictGet root "job_id" undefined
                if owner == undefined then undefined
                else (
                    local ownerText = try(owner as string)catch(undefined)
                    if ownerText == undefined or ownerText == "" then undefined else ownerText
                )
            )
        )
    )
)

fn VF_TaskFileBelongsToJob jobId = (
    -- Дублировавшиеся чтение файла и разбор JSON перенесены в
    -- VF_TryReadTaskJobId. Сравнение владельца осталось точным и не принимает
    -- пустой, повреждённый или чужой идентификатор.
    local owner = VF_TryReadTaskJobId()
    if owner == undefined then false else (owner == (jobId as string))
)

fn VF_RequireTaskOwnership task = (
    -- Контрольные точки транзакции превращают удаление задания
    -- при закрытии Vertex Flow в штатную отмену. Исключение попадает в уже
    -- существующий transactional catch, после чего удаляются только ресурсы,
    -- созданные текущим импортом, и восстанавливается состояние пользователя.
    if not (VF_TaskFileBelongsToJob task.jobId) do (
        VF_Fail "ERR_TASK_CANCELLED" "Vertex Flow task was cancelled"
    )
    true
)

fn VF_AsString value fieldName allowEmpty:false = (
    if value == undefined do VF_Fail "ERR_TASK_SCHEMA" ("Missing field: " + fieldName)
    local text = value as string
    if (not allowEmpty and text == "") or text.count > 32767 do VF_Fail "ERR_TASK_SCHEMA" ("Invalid field: " + fieldName)
    if (findString text "\r") != undefined or (findString text "\n") != undefined do VF_Fail "ERR_TASK_SCHEMA" ("Control character in " + fieldName)
    text
)

fn VF_AsBool value fieldName = (
    -- Единственный текущий Rust-контракт передаёт настоящий JSON
    -- boolean. Поддержка строк "true"/"false" удалена как legacy-ветка.
    if value == true then true
    else if value == false then false
    else VF_Fail "ERR_TASK_SCHEMA" ("Invalid boolean field: " + fieldName)
)

fn VF_NormalizePath pathValue = (
    local pathClass = dotNetClass "System.IO.Path"
    local value = pathValue as string
    try (
        -- Относительная подстановка через modelDir использовалась
        -- только mappings-алгоритмом и удалена вместе с ним.
        toLower (pathClass.GetFullPath value)
    ) catch (
        VF_Fail "ERR_PATH_INVALID" ("Invalid path: " + value)
    )
)

fn VF_IsAbsolute pathValue = (
    try((dotNetClass "System.IO.Path").IsPathRooted (pathValue as string))catch(false)
)

-- [УДАЛЕНО]: Вызов несуществующей функции doesDirectoryExist удалён.
-- MAXScript не объявляет такую встроенную функцию, поэтому при включённом
-- relink_textures проверка абсолютного textures_path доходила до undefined и
-- завершалась ошибкой "Call needs function or class, got: undefined" до импорта.
--
-- [ДОБАВЛЕНО]: Проверка каталога выполняется штатным System.IO.Directory.Exists
-- через документированный Autodesk dotNetClass. Метод ничего не создаёт и не
-- изменяет на диске: он только возвращает true для существующего каталога.
fn VF_DirectoryExists pathValue = (
    local directoryClass = try(dotNetClass "System.IO.Directory")catch(undefined)
    if directoryClass == undefined then false
    else try(directoryClass.Exists (pathValue as string))catch(false)
)

fn VF_CurrentProjectPath = (
    if maxFileName == "" then "" else (maxFilePath + maxFileName)
)

fn VF_ParseTask rawJson = (
    if not (VF_InitJson()) do VF_Fail "ERR_JSON_BACKEND_UNAVAILABLE" "System.Web JSON backend is unavailable"
    local root = try(VertexFlow_JSONSerializer.DeserializeObject rawJson)catch(undefined)
    if root == undefined do VF_Fail "ERR_TASK_JSON" "Task JSON is invalid"

    local task = VFTask()
    task.status = VF_AsString (VF_DictGet root "status" undefined) "status"
    -- job_id обязателен для задания и любого ответа; версия
    -- протокола больше не нужна, потому что до релиза существует один контракт.
    task.jobId = VF_AsString (VF_DictGet root "job_id" undefined) "job_id"
    -- Terminal/processing responses intentionally contain no input paths. They
    -- must be ignored instead of being reclassified as malformed tasks.
    if task.status != "pending" do return task
    task.modelPath = VF_AsString (VF_DictGet root "model_path" undefined) "model_path"
    task.projectPath = VF_AsString (VF_DictGet root "project_path" undefined) "project_path"
    task.texturesPath = VF_AsString (VF_DictGet root "textures_path" "") "textures_path" allowEmpty:true
    task.relinkTextures = VF_AsBool (VF_DictGet root "relink_textures" undefined) "relink_textures"

    -- created_at_ms также обязателен; необязательная legacy-ветка
    -- удалена, чтобы зависшее задание нельзя было принять без возраста.
    local created = VF_DictGet root "created_at_ms" undefined
    local nowMs = try((dotNetClass "System.DateTimeOffset").UtcNow.ToUnixTimeMilliseconds())catch(undefined)
    local createdMs = try(created as integer64)catch(VF_Fail "ERR_TASK_SCHEMA" "created_at_ms must be integer")
    if nowMs != undefined do (
        local age = nowMs - createdMs
        if age > VF_MAX_TASK_AGE_MS or age < -60000L do VF_Fail "ERR_TASK_STALE" "Task timestamp is stale or in the future"
    )
    task
)

fn VF_ReadTask = (
    local fileClass = dotNetClass "System.IO.File"
    if not (fileClass.Exists VF_TASK_FILE) then undefined
    else (
        local fileInfo = dotNetObject "System.IO.FileInfo" VF_TASK_FILE
        if fileInfo.Length <= 0 or fileInfo.Length > VF_MAX_TASK_BYTES do VF_Fail "ERR_TASK_SIZE" "Task file has invalid size"
        local utf8 = dotNetObject "System.Text.UTF8Encoding" false
        local raw = try(fileClass.ReadAllText VF_TASK_FILE utf8)catch(VF_Fail "ERR_TASK_READ" "Cannot read task file")
        VF_ParseTask raw
    )
)

fn VF_ValidateTask task = (
    if task.status != "pending" then false
    else (
        if (findItem VertexFlow_ProcessedJobs task.jobId) > 0 then false
        else (
            if not (VF_IsAbsolute task.modelPath) or not (VF_IsAbsolute task.projectPath) do VF_Fail "ERR_PATH_NOT_ABSOLUTE" "Model/project paths must be absolute"
            if not (doesFileExist task.modelPath) do VF_Fail "ERR_MODEL_NOT_FOUND" "Model file does not exist"
            local currentProject = VF_CurrentProjectPath()
            if currentProject == "" do VF_Fail "ERR_SCENE_NOT_SAVED" "The current 3ds Max scene must be saved"
            if (VF_NormalizePath currentProject) != (VF_NormalizePath task.projectPath) do VF_Fail "ERR_PROJECT_MISMATCH" "Open scene does not match task project"
            local extension = toLower (getFilenameType task.modelPath)
            if (findItem #(".max", ".fbx", ".obj") extension) == 0 do VF_Fail "ERR_UNSUPPORTED_FORMAT" ("Unsupported format: " + extension)
            if task.relinkTextures do (
                -- Невалидный doesDirectoryExist заменён на
                -- VF_DirectoryExists, использующий System.IO.Directory.Exists.
                -- Порядок и смысл проверки не изменены: каталог обязателен
                -- только когда пользователь включил переназначение текстур.
                if task.texturesPath == "" or not (VF_IsAbsolute task.texturesPath) or not (VF_DirectoryExists task.texturesPath) do VF_Fail "ERR_TEXTURES_DIR" "textures_path must be an existing absolute directory"
            )
            true
        )
    )
)

fn VF_AnimSeen values value = ((findItem values value) > 0)

fn VF_GetNumSubMtlsSafe value = try(getNumSubMtls value)catch(0)
fn VF_GetNumSubMapsSafe value = try(getNumSubTexmaps value)catch(0)
fn VF_GetSubMtlSafe value index = try(getSubMtl value index)catch(undefined)
fn VF_GetSubMapSafe value index = try(getSubTexmap value index)catch(undefined)

fn VF_LooksLikeExternalAsset value = (
    if value == undefined or not (isKindOf value String) or value == "" then false
    else (
        local extension = toLower (getFilenameType value)
        VF_IsAbsolute value or (findItem #(".bmp", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".tga", ".exr", ".hdr", ".dds", ".tx", ".rat", ".ies") extension) > 0
    )
)

fn VF_GetFilePropertyNames mapValue = (
    -- Помимо известных Standard/V-Ray/Corona/Arnold имён,
    -- проверяются строковые свойства стороннего TextureMap, реально похожие на
    -- файловую зависимость. Неизвестный класс не требует загрузки его плагина.
    local result = for propertyName in VF_FILE_PROPERTIES where isProperty mapValue propertyName collect propertyName
    local properties = try(getPropNames mapValue)catch(#())
    for propertyName in properties where (findItem result propertyName) == 0 do (
        local current = try(getProperty mapValue propertyName)catch(undefined)
        if VF_LooksLikeExternalAsset current do append result propertyName
    )
    result
)

fn VF_CaptureFileProperties mapValue stateArray = (
    for propertyName in VF_GetFilePropertyNames mapValue do (
        local current = try(getProperty mapValue propertyName)catch(undefined)
        if current != undefined and isKindOf current String and current != "" do append stateArray #(mapValue, propertyName, current)
    )
)

fn VF_CollectMapGraph mapValue materials maps mapPathStates:undefined = (
    if mapValue == undefined or VF_AnimSeen maps mapValue then false
    else (
        append maps mapValue
        if mapPathStates != undefined do VF_CaptureFileProperties mapValue mapPathStates
        for index = 1 to (VF_GetNumSubMapsSafe mapValue) do VF_CollectMapGraph (VF_GetSubMapSafe mapValue index) materials maps mapPathStates:mapPathStates
        for index = 1 to (VF_GetNumSubMtlsSafe mapValue) do VF_CollectMaterialGraph (VF_GetSubMtlSafe mapValue index) materials maps mapPathStates:mapPathStates
        true
    )
)

fn VF_CollectMaterialGraph materialValue materials maps mapPathStates:undefined = (
    if materialValue == undefined or VF_AnimSeen materials materialValue then false
    else (
        append materials materialValue
        for index = 1 to (VF_GetNumSubMtlsSafe materialValue) do VF_CollectMaterialGraph (VF_GetSubMtlSafe materialValue index) materials maps mapPathStates:mapPathStates
        for index = 1 to (VF_GetNumSubMapsSafe materialValue) do VF_CollectMapGraph (VF_GetSubMapSafe materialValue index) materials maps mapPathStates:mapPathStates
        true
    )
)

fn VF_CollectModifierMaps nodeValue materials maps mapPathStates:undefined = (
    for modifierValue in nodeValue.modifiers do (
        for propertyName in #(#map, #texture, #displacementMap) where isProperty modifierValue propertyName do (
            local mapValue = try(getProperty modifierValue propertyName)catch(undefined)
            if mapValue != undefined do VF_CollectMapGraph mapValue materials maps mapPathStates:mapPathStates
        )
    )
)

fn VF_CaptureLayers = (
    local result = #()
    for index = 0 to LayerManager.count - 1 do append result (LayerManager.getLayer index)
    result
)

fn VF_CaptureScene = (
    -- До Merge/import сохраняются handles и ссылки на объекты.
    -- Выделение и имена не используются для определения новых узлов.
    local snapshot = VFSceneSnapshot()
    snapshot.nodes = objects as array
    snapshot.nodeHandles = for nodeValue in snapshot.nodes collect (getHandleByAnim nodeValue)
    snapshot.selectedNodes = selection as array
    snapshot.subObject = subObjectLevel
    snapshot.layers = VF_CaptureLayers()
    for nodeValue in snapshot.nodes do (
        append snapshot.nodeStates #(nodeValue, nodeValue.transform, nodeValue.parent, nodeValue.material, nodeValue.layer)
        VF_CollectMaterialGraph nodeValue.material snapshot.oldMaterials snapshot.oldMaps mapPathStates:snapshot.mapPathStates
        VF_CollectModifierMaps nodeValue snapshot.oldMaterials snapshot.oldMaps mapPathStates:snapshot.mapPathStates
    )
    snapshot.environmentMapValue = try(environmentMap)catch(undefined)
    if snapshot.environmentMapValue != undefined do VF_CollectMapGraph snapshot.environmentMapValue snapshot.oldMaterials snapshot.oldMaps mapPathStates:snapshot.mapPathStates
    snapshot.backgroundColorValue = try(backgroundColor)catch(undefined)
    snapshot.ambientColorValue = try(ambientColor)catch(undefined)
    snapshot.commandPanelMode = try(getCommandPanelTaskMode())catch(undefined)
    snapshot
)

fn VF_GetNewNodes snapshot = (
    local result = #()
    for nodeValue in objects do (
        local handle = getHandleByAnim nodeValue
        if (findItem snapshot.nodeHandles handle) == 0 do append result nodeValue
    )
    result
)

fn VF_CacheGet cache source = (
    for pair in cache where pair[1] == source do return pair[2]
    undefined
)

fn VF_CachePut cache source localized = (append cache #(source, localized); localized)

fn VF_LocalizeMap mapValue snapshot materialCache mapCache = (
    if mapValue == undefined then undefined
    else (
        local cached = VF_CacheGet mapCache mapValue
        if cached != undefined then cached
        else (
            local localized = mapValue
            if (findItem snapshot.oldMaps mapValue) > 0 do (
                localized = try(copy mapValue)catch(undefined)
                if localized == undefined do VF_Fail "ERR_SHARED_MAP_ISOLATION" ("Cannot clone shared map: " + mapValue.name)
            )
            VF_CachePut mapCache mapValue localized
            for index = 1 to (VF_GetNumSubMapsSafe localized) do (
                local child = VF_GetSubMapSafe localized index
                if child != undefined do try(setSubTexmap localized index (VF_LocalizeMap child snapshot materialCache mapCache))catch(VF_Fail "ERR_SHARED_MAP_ISOLATION" "Cannot assign cloned sub-map")
            )
            for index = 1 to (VF_GetNumSubMtlsSafe localized) do (
                local childMaterial = VF_GetSubMtlSafe localized index
                if childMaterial != undefined do try(setSubMtl localized index (VF_LocalizeMaterial childMaterial snapshot materialCache mapCache))catch(VF_Fail "ERR_SHARED_MATERIAL_ISOLATION" "Cannot assign cloned sub-material")
            )
            localized
        )
    )
)

fn VF_LocalizeMaterial materialValue snapshot materialCache mapCache = (
    if materialValue == undefined then undefined
    else (
        local cached = VF_CacheGet materialCache materialValue
        if cached != undefined then cached
        else (
            local localized = materialValue
            if (findItem snapshot.oldMaterials materialValue) > 0 do (
                localized = try(copy materialValue)catch(undefined)
                if localized == undefined do VF_Fail "ERR_SHARED_MATERIAL_ISOLATION" ("Cannot clone shared material: " + materialValue.name)
            )
            VF_CachePut materialCache materialValue localized
            for index = 1 to (VF_GetNumSubMtlsSafe localized) do (
                local childMaterial = VF_GetSubMtlSafe localized index
                if childMaterial != undefined do try(setSubMtl localized index (VF_LocalizeMaterial childMaterial snapshot materialCache mapCache))catch(VF_Fail "ERR_SHARED_MATERIAL_ISOLATION" "Cannot assign cloned sub-material")
            )
            for index = 1 to (VF_GetNumSubMapsSafe localized) do (
                local childMap = VF_GetSubMapSafe localized index
                if childMap != undefined do try(setSubTexmap localized index (VF_LocalizeMap childMap snapshot materialCache mapCache))catch(VF_Fail "ERR_SHARED_MAP_ISOLATION" "Cannot assign cloned sub-map")
            )
            localized
        )
    )
)

fn VF_LocalizeImportedNodes importedNodes snapshot = (
    local materialCache = #()
    local mapCache = #()
    for nodeValue in importedNodes do (
        if nodeValue.material != undefined do nodeValue.material = VF_LocalizeMaterial nodeValue.material snapshot materialCache mapCache
        for modifierValue in nodeValue.modifiers do (
            for propertyName in #(#map, #texture, #displacementMap) where isProperty modifierValue propertyName do (
                local mapValue = try(getProperty modifierValue propertyName)catch(undefined)
                if mapValue != undefined do try(setProperty modifierValue propertyName (VF_LocalizeMap mapValue snapshot materialCache mapCache))catch(VF_Fail "ERR_SHARED_MAP_ISOLATION" "Cannot isolate modifier map")
            )
        )
    )
)

fn VF_ResolveTexture oldPath task warnings = (
    -- Это основной и единственный алгоритм Vertex Flow: Rust уже
    -- скопировал текстуры в одну выбранную папку с уникальными именами. Поэтому
    -- мост берёт имя из старого пути и подставляет textures_path без mappings.
    local basename = filenameFromPath oldPath
    if basename == "" then (
        append warnings ("WARN_TEXTURE_UNMAPPED: " + oldPath)
        undefined
    ) else (
        local target = (dotNetClass "System.IO.Path").Combine task.texturesPath basename
        if doesFileExist target then target
        else (
            append warnings ("WARN_TEXTURE_UNMAPPED: " + oldPath)
            undefined
        )
    )
)

fn VF_HasSequenceToken value = (
    -- Проверка регистронезависима и отдельно учитывает IFL —
    -- официальный контейнер 3ds Max для последовательности кадров. Без полного
    -- шаблона/содержимого многокомпонентный источник не переназначается одним
    -- basename, чтобы не получить тихо повреждённую последовательность или UDIM.
    local text = value as string
    local upperValue = toUpper text
    local extension = toLower (getFilenameType text)
    extension == ".ifl" or
    (findString upperValue "<UDIM>") != undefined or
    (findString upperValue "<UVTILE>") != undefined or
    (findString upperValue "####") != undefined or
    (findString upperValue "%0") != undefined
)

fn VF_RelinkImported task importedNodes snapshot warnings journal = (
    if not task.relinkTextures then 0
    else (
        local materials = #()
        local maps = #()
        for nodeValue in importedNodes do (
            VF_CollectMaterialGraph nodeValue.material materials maps
            VF_CollectModifierMaps nodeValue materials maps
        )
        local changed = 0
        for mapValue in maps do (
            if (findItem snapshot.oldMaps mapValue) > 0 do VF_Fail "ERR_SHARED_MAP_ISOLATION" "A pre-existing map reached mutation stage"
            local foundProperty = false
            for propertyName in VF_GetFilePropertyNames mapValue do (
                local oldPath = try(getProperty mapValue propertyName)catch(undefined)
                if oldPath != undefined and isKindOf oldPath String and oldPath != "" do (
                    foundProperty = true
                    if VF_HasSequenceToken oldPath then append warnings ("WARN_UDIM_OR_SEQUENCE_SKIPPED: " + oldPath)
                    else (
                        local target = VF_ResolveTexture oldPath task warnings
                        if target != undefined do (
                            if not (doesFileExist target) do VF_Fail "ERR_TEXTURE_TARGET_MISSING" ("Target texture does not exist: " + target)
                            append journal #(mapValue, propertyName, oldPath)
                            try(setProperty mapValue propertyName target)catch(VF_Fail "ERR_TEXTURE_ASSIGN" ("Cannot set texture path: " + (propertyName as string)))
                            local stored = try(getProperty mapValue propertyName)catch("")
                            if (VF_NormalizePath stored) != (VF_NormalizePath target) do VF_Fail "ERR_TEXTURE_VERIFY" "Texture property verification failed"
                            changed += 1
                        )
                    )
                )
            )
            -- Procedural maps legitimately expose no filename property.
            if not foundProperty do ok
        )
        changed
    )
)

fn VF_VerifyExistingScene snapshot = (
    for state in snapshot.nodeStates do (
        local nodeValue = state[1]
        if not (isValidNode nodeValue) do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing node was removed"
        if nodeValue.transform != state[2] do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing transform changed"
        if nodeValue.parent != state[3] do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing parent changed"
        if nodeValue.material != state[4] do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing material assignment changed"
        if nodeValue.layer != state[5] do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing layer assignment changed"
    )
    for state in snapshot.mapPathStates do (
        local current = try(getProperty state[1] state[2])catch(undefined)
        if current != state[3] do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "A pre-existing texture path changed"
    )
    if try(environmentMap != snapshot.environmentMapValue)catch(false) do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "Environment map changed"
    if try(backgroundColor != snapshot.backgroundColorValue)catch(false) do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "Background color changed"
    if try(ambientColor != snapshot.ambientColorValue)catch(false) do VF_Fail "ERR_SCENE_PROTECTION_VIOLATION" "Ambient color changed"
    true
)

fn VF_RestoreUserState snapshot strict:false warnings:undefined = (
    local restoreFailed = false
    try(clearSelection())catch(restoreFailed = true)
    local validSelection = for nodeValue in snapshot.selectedNodes where isValidNode nodeValue collect nodeValue
    if validSelection.count > 0 do try(select validSelection)catch(restoreFailed = true)
    try(subObjectLevel = snapshot.subObject)catch(restoreFailed = true)
    if snapshot.commandPanelMode != undefined do try(setCommandPanelTaskMode snapshot.commandPanelMode)catch(restoreFailed = true)
    if selection.count != validSelection.count do restoreFailed = true
    if restoreFailed then (
        if warnings != undefined do append warnings "WARN_USER_STATE_RESTORE_FAILED"
        if strict do VF_Fail "ERR_USER_STATE_RESTORE" "Cannot restore 3ds Max user state"
    )
    not restoreFailed
)

fn VF_RefreshAssetTracking strict:false warnings:undefined = (
    -- freeSceneBitmaps и глобальные изменения ассетов удалены.
    -- ATSOps.Refresh только обновляет штатное представление Asset Tracking.
    local refreshed = try(ATSOps.Refresh(); true)catch(false)
    if not refreshed do (
        VertexFlow_LogMsg "WARN_ATS_REFRESH_FAILED" level:"WARNING"
        if warnings != undefined do append warnings "WARN_ATS_REFRESH_FAILED"
        if strict do VF_Fail "ERR_ATS_REFRESH_FAILED" "Asset Tracking could not be refreshed"
    )
    refreshed
)

fn VF_RestoreExistingScene snapshot warnings = (
    -- Rollback восстанавливает зафиксированные значения старых
    -- узлов/карт/Environment, если штатный importer успел изменить их до сбоя.
    for state in snapshot.nodeStates do (
        local nodeValue = state[1]
        if isValidNode nodeValue then (
            try(nodeValue.parent = state[3])catch(append warnings "ROLLBACK_PARENT_RESTORE_FAILED")
            try(nodeValue.transform = state[2])catch(append warnings "ROLLBACK_TRANSFORM_RESTORE_FAILED")
            try(nodeValue.material = state[4])catch(append warnings "ROLLBACK_MATERIAL_RESTORE_FAILED")
            try(state[5].addNode nodeValue)catch(append warnings "ROLLBACK_LAYER_RESTORE_FAILED")
        ) else append warnings "ROLLBACK_OLD_NODE_MISSING"
    )
    for state in snapshot.mapPathStates do try(setProperty state[1] state[2] state[3])catch(append warnings "ROLLBACK_OLD_TEXTURE_RESTORE_FAILED")
    try(environmentMap = snapshot.environmentMapValue)catch(append warnings "ROLLBACK_ENVIRONMENT_RESTORE_FAILED")
    try(backgroundColor = snapshot.backgroundColorValue)catch(append warnings "ROLLBACK_BACKGROUND_RESTORE_FAILED")
    try(ambientColor = snapshot.ambientColorValue)catch(append warnings "ROLLBACK_AMBIENT_RESTORE_FAILED")
)

fn VF_Rollback snapshot journal = (
    local warnings = #()
    for index = journal.count to 1 by -1 do (
        local entry = journal[index]
        try(setProperty entry[1] entry[2] entry[3])catch(append warnings "ROLLBACK_TEXTURE_PROPERTY_FAILED")
    )
    VF_RestoreExistingScene snapshot warnings
    -- Получение новых узлов во время rollback теперь защищено.
    -- Раньше редкое исключение getHandleByAnim/обхода сцены прерывало весь
    -- rollback и не позволяло выполнить последующие восстановительные шаги.
    local newNodes = try(VF_GetNewNodes snapshot)catch(
        append warnings ("ROLLBACK_NEW_NODE_SCAN_FAILED: " + getCurrentException())
        #()
    )
    for nodeValue in newNodes do try(delete nodeValue)catch(append warnings ("ROLLBACK_NODE_DELETE_FAILED: " + nodeValue.name))
    -- Remove only layers created by this operation, and only when no node remains.
    -- Ошибка чтения LayerManager больше не обрывает восстановление
    -- выделения, режима пользователя и Asset Tracking.
    local currentLayers = try(VF_CaptureLayers())catch(
        append warnings ("ROLLBACK_LAYER_SCAN_FAILED: " + getCurrentException())
        #()
    )
    for layerValue in currentLayers where (findItem snapshot.layers layerValue) == 0 do (
        local layerNodes = #()
        try(layerValue.nodes &layerNodes)catch()
        if layerNodes.count == 0 do try(LayerManager.deleteLayerByName layerValue.name)catch(append warnings ("ROLLBACK_LAYER_DELETE_FAILED: " + layerValue.name))
    )
    VF_RestoreUserState snapshot warnings:warnings
    VF_RefreshAssetTracking warnings:warnings
    try(VF_VerifyExistingScene snapshot)catch(append warnings ("ROLLBACK_SCENE_VERIFY_FAILED: " + getCurrentException()))
    -- Финальная проверка rollback тоже не может выбросить исключение
    -- наружу и скрыть исходную причину импорта; сбой самой проверки возвращается
    -- как точное предупреждение ERR_ROLLBACK_FAILED.
    local remainingNodeCount = try((VF_GetNewNodes snapshot).count)catch(
        append warnings ("ROLLBACK_FINAL_SCAN_FAILED: " + getCurrentException())
        -1
    )
    if remainingNodeCount > 0 do append warnings "ROLLBACK_NEW_NODES_REMAIN"
    warnings
)

fn VF_ImportModel task = (
    local extension = toLower (getFilenameType task.modelPath)
    local result = false
    if extension == ".max" then (
        -- Merge не заменяет узлы и материалы с совпавшими именами,
        -- а принадлежность новых узлов не определяется по выделению.
        result = mergeMAXFile task.modelPath #select #autoRenameDups #renameMtlDups #neverReparent quiet:true
    ) else if extension == ".fbx" or extension == ".obj" then (
        result = importFile task.modelPath #noPrompt
    ) else VF_Fail "ERR_UNSUPPORTED_FORMAT" ("Unsupported format: " + extension)
    result == true
)

fn VF_ExecuteTransaction task = (
    -- Локальная фаза транзакции дополняет внешнюю диагностику.
    -- Она не влияет на rollback и нужна только для точного определения места
    -- ошибки после того, как processing уже опубликован приложению.
    local phase = "capture_scene"
    local snapshot = VF_CaptureScene()
    local journal = #()
    local warnings = #()
    local importedNodes = #()
    try (
        -- До первого изменения сцены убеждаемся, что приложение
        -- не закрылось и всё ещё ожидает результат именно этого задания.
        phase = "ownership_before_import"
        VF_RequireTaskOwnership task
        phase = "import_model"
        if not (VF_ImportModel task) do VF_Fail "ERR_IMPORT_FAILED" "3ds Max importer returned false"
        -- mergeMAXFile/importFile выполняются синхронно. Если
        -- Vertex Flow закрылся во время штатного импортёра, удаление task-файла
        -- обнаруживается сразу после его возврата и запускает rollback.
        phase = "ownership_after_import"
        VF_RequireTaskOwnership task
        phase = "collect_imported_nodes"
        importedNodes = VF_GetNewNodes snapshot
        if importedNodes.count == 0 do VF_Fail "ERR_NO_IMPORTED_OBJECTS" "Importer created no new nodes"
        phase = "isolate_shared_resources"
        VF_LocalizeImportedNodes importedNodes snapshot
        -- Вторая контрольная точка не позволяет продолжить
        -- переназначение путей после отмены задания приложением.
        phase = "ownership_before_relink"
        VF_RequireTaskOwnership task
        phase = "relink_textures"
        local relinked = VF_RelinkImported task importedNodes snapshot warnings journal
        -- Финальная контрольная точка выполняется до подтверждения
        -- транзакции. Отмена во время обхода материалов также приводит к rollback.
        phase = "ownership_before_commit"
        VF_RequireTaskOwnership task
        phase = "verify_existing_scene"
        VF_VerifyExistingScene snapshot
        phase = "restore_user_state"
        VF_RestoreUserState snapshot strict:true
        phase = "refresh_asset_tracking"
        VF_RefreshAssetTracking strict:true
        local status = if warnings.count > 0 then "completed_with_warnings" else "completed"
        local details = "{\"imported_nodes\":" + (importedNodes.count as string) + ",\"relinked_paths\":" + (relinked as string) + "}"
        #(true, status, warnings, details, snapshot, journal)
    ) catch (
        local originalCode = VertexFlow_LastErrorCode
        local originalMessage = getCurrentException()
        local originalPhase = phase
        -- Теперь Console сразу показывает точную фазу и причину.
        VertexFlow_LogMsg (originalCode + " [phase=" + phase + "]: " + originalMessage) level:"ERROR"
        phase = "rollback"
        local rollbackWarnings = VF_Rollback snapshot journal
        if rollbackWarnings.count > 0 then (
            VertexFlow_LastErrorCode = "ERR_ROLLBACK_FAILED"
            #(false, "error", rollbackWarnings, "{\"rollback\":\"incomplete\",\"original_code\":\"" + VF_JsonEscape originalCode + "\",\"original_phase\":\"" + VF_JsonEscape originalPhase + "\"}", snapshot, journal)
        ) else (
            VertexFlow_LastErrorCode = originalCode
            #(false, "rolled_back", #(), "{\"rollback\":\"completed\",\"original_phase\":\"" + VF_JsonEscape originalPhase + "\",\"original_message\":\"" + VF_JsonEscape originalMessage + "\"}", snapshot, journal)
        )
    )
)

fn VertexFlow_ProcessTask sender eventArgs = (
    if VertexFlow_Busy do return false
    if not (doesFileExist VF_TASK_FILE) do return false
    local task = VFTask()
    local shouldRestart = VertexFlow_Listening
    -- phase отмечает последний начатый этап, чтобы внутреннее
    -- исключение больше не теряло место возникновения во внешнем catch.
    -- Это только диагностика; порядок операций и JSON-протокол не меняются.
    local phase = "initialize"
    if VertexFlow_Timer != undefined do VertexFlow_Timer.Stop()
    VertexFlow_Busy = true
    VertexFlow_LastErrorCode = "ERR_MAX_INTERNAL"
    try (
        phase = "read_task"
        task = VF_ReadTask()
        phase = "validate_task"
        if task == undefined or not (VF_ValidateTask task) then ok
        else (
            -- Теперь импорт начинается только после успешной публикации processing.
            phase = "publish_processing"
            if not (VF_WriteResult task "processing" undefined "3ds Max is processing the task") then (
                VertexFlow_LogMsg "TASK_CANCELLED: import was not started" level:"WARNING"
                --  Если приложение удалило/заменило task-файл,
                -- это штатная отмена и listener продолжает ждать новые задания.
                -- Если же pending-файл всё ещё наш, публикация processing реально
                -- сломана; повторять её каждую секунду означало бы флудить лог.
                local pendingStillOwned = try(VF_TaskFileBelongsToJob task.jobId)catch(false)
                if pendingStillOwned do (
                    shouldRestart = false
                    VertexFlow_Listening = false
                    VertexFlow_LogMsg "Listening stopped: processing response could not be published" level:"WARNING"
                )
            ) else (
                VertexFlow_LogMsg ("Import started: " + filenameFromPath task.modelPath)
                phase = "execute_transaction"
                local result = VF_ExecuteTransaction task
                if result[1] then (
                    local finalMessage = if result[3].count > 0 then "Import completed with warnings" else "Import completed"
                    phase = "publish_success"
                    if (VF_WriteResult task result[2] undefined finalMessage warnings:result[3] detailsJson:result[4]) then (
                        -- Задание считается обработанным только после
                        -- успешной публикации terminal-ответа. Это исключает ложный
                        -- локальный success, который приложение никогда не увидело.
                        append VertexFlow_ProcessedJobs task.jobId
                        if VertexFlow_ProcessedJobs.count > 128 do deleteItem VertexFlow_ProcessedJobs 1
                        VertexFlow_LogMsg finalMessage level:(if result[3].count > 0 then "WARNING" else "INFO")
                    ) else (
                        -- Если Vertex Flow закрылся после завершения
                        -- импортёра, но до публикации результата, успешная локальная
                        -- транзакция откатывается. Мост не оставляет в коммерческой
                        -- сцене импорт, который приложение считает отменённым.
                        local cancelWarnings = VF_Rollback result[5] result[6]
                        if cancelWarnings.count > 0 then (
                            VertexFlow_LogMsg "ERR_ROLLBACK_FAILED: cancelled import was not fully rolled back" level:"ERROR"
                        ) else (
                            VertexFlow_LogMsg "TASK_CANCELLED: completed import was rolled back" level:"WARNING"
                        )
                    )
                ) else (
                    -- Ошибка транзакции уже сопровождается rollback.
                    -- Если приложение ещё работает, оно получает точный ответ;
                    -- если task-файл удалён при закрытии, мост только фиксирует
                    -- отмену в Listener и не воссоздаёт JSON.
                    phase = "publish_transaction_error"
                    if (VF_WriteResult task result[2] VertexFlow_LastErrorCode "Import failed" warnings:result[3] detailsJson:result[4]) then (
                        VertexFlow_LogMsg (VertexFlow_LastErrorCode + ": Import failed") level:"ERROR"
                    ) else (
                        VertexFlow_LogMsg (VertexFlow_LastErrorCode + ": rollback completed; response was not published") level:"WARNING"
                    )
                )
            )
        )
    ) catch (
        local message = getCurrentException()
        -- Фиксируем лог и фазу.
        VertexFlow_LogMsg (VertexFlow_LastErrorCode + " [phase=" + phase + "]: " + message) level:"ERROR"

        -- Начиная с 3ds Max 2017 MAXScript умеет отдавать стек
        -- текущего исключения внутри catch. Мост поддерживает 2022+, поэтому
        -- диагностический стек доступен; безопасный try оставляет совместимый
        -- fallback, если конкретная сборка не сформировала стек.
        local stackTrace = try(
            if hasCurrentExceptionStackTrace() then (getCurrentExceptionStackTrace() as string) else ""
        )catch("")
        if stackTrace != undefined and stackTrace != "" do VertexFlow_LogMsg ("MAXScript stack: " + stackTrace) level:"ERROR"

        if task.jobId == "" do (
            -- Аварийное повторное чтение одного job_id теперь само
            -- защищено. Раньше второе исключение внутри catch могло выйти наружу,
            -- оставить VertexFlow_Busy=true и Timer остановленным навсегда.
            local recoveredJobId = try(VF_TryReadTaskJobId())catch(
                VertexFlow_LogMsg ("ERR_TASK_OWNER_RECOVERY [phase=" + phase + "]: " + getCurrentException()) level:"ERROR"
                undefined
            )
            if recoveredJobId != undefined do task.jobId = recoveredJobId
        )

        -- Если JSON сломан ещё до чтения обязательного job_id,
        -- мост не публикует ответ без владельца. Rust сам отклонит исходный файл.
        if task.jobId == "" then (
            -- Атомарно созданный, но не позволяющий подтвердить
            -- job_id файл нельзя безопасно заменить ответом. Чтобы такой файл не
            -- вызывал одно и то же исключение каждую секунду, listener переходит
            -- в явный fail-safe stop; сцена и сам 3ds Max не затрагиваются.
            if doesFileExist VF_TASK_FILE do (
                shouldRestart = false
                VertexFlow_Listening = false
                VertexFlow_LogMsg "Listening stopped: task owner could not be verified" level:"WARNING"
            )
        ) else (
            -- Ошибка записи ответа больше не скрывается пустым catch.
            -- Если общий task-файл нельзя атомарно заменить, повторять весь
            -- неисправный цикл каждую секунду небезопасно: это создаёт флуд и
            -- может многократно запускать подготовительную логику. Listener
            -- останавливается явно, но 3ds Max и сцена продолжают работать.
            local errorPublished = false
            try(
                errorPublished = VF_WriteResult task "error" VertexFlow_LastErrorCode ("[phase=" + phase + "] " + message)
            )catch(
                VertexFlow_LogMsg ("ERR_RESULT_WRITE [phase=" + phase + "]: " + getCurrentException()) level:"ERROR"
            )
            if not errorPublished do (
                -- Удалённое приложением задание является штатной
                -- отменой и не отключает listener. Он останавливается только
                -- если файл всё ещё принадлежит этому job_id, но terminal-ответ
                -- записать не удалось — именно такой случай раньше флудил лог.
                local taskStillOwned = try(VF_TaskFileBelongsToJob task.jobId)catch(false)
                if taskStillOwned do (
                    shouldRestart = false
                    VertexFlow_Listening = false
                    VertexFlow_LogMsg "Listening stopped: terminal response could not be published" level:"WARNING"
                )
            )
        )
    )
    VertexFlow_Busy = false
    if shouldRestart and VertexFlow_Timer != undefined do VertexFlow_Timer.Start()
    true
)

try(destroyDialog VertexFlowListenerUI)catch()
rollout VertexFlowListenerUI "Vertex Flow: Console" width:370 height:340 (
    label lblStatus "Status: [ LISTENING ]" pos:[10,10] width:350
    label lblLastAction "-" pos:[10,30] width:350
    button btnToggle "Stop Listening" pos:[10,50] width:350 height:30
    button btnManual "Manual Check" pos:[10,85] width:350 height:25
    label lblLogTitle "Event Log:" pos:[10,120]
    edittext txtLog "" pos:[10,140] width:350 height:185 readOnly:true

    fn UpdateUI = (
        local fullText = ""
        for message in VertexFlow_Log do fullText += message + "\r\n"
        txtLog.text = fullText
        if VertexFlow_Log.count > 0 do lblLastAction.text = VertexFlow_Log[1]
        if VertexFlow_Listening then (
            lblStatus.text = "Status: [ LISTENING ]"
            btnToggle.text = "Stop Listening"
        ) else (
            lblStatus.text = "Status: [ DISABLED ]"
            btnToggle.text = "Start Listening"
        )
    )

    on VertexFlowListenerUI open do (VertexFlow_UpdateUI = UpdateUI; UpdateUI())
    on VertexFlowListenerUI close do (VertexFlow_UpdateUI = undefined)
    on btnToggle pressed do (
        VertexFlow_Listening = not VertexFlow_Listening
        if VertexFlow_Timer != undefined do (
            if VertexFlow_Listening then VertexFlow_Timer.Start() else VertexFlow_Timer.Stop()
        )
        VertexFlow_LogMsg (if VertexFlow_Listening then "Listening started" else "Listening stopped") level:(if VertexFlow_Listening then "INFO" else "WARNING")
    )
    on btnManual pressed do VertexFlow_ProcessTask undefined undefined
)

global VertexFlow_OpenUI
fn VertexFlow_OpenUI = (
    try(destroyDialog VertexFlowListenerUI)catch()
    createDialog VertexFlowListenerUI style:#(#style_toolwindow, #style_sysmenu)
)

-- Повторный запуск .ms останавливает прежний Timer и его handlers;
-- callbacks не накапливаются после startup, fileIn или обновления скрипта.
if VertexFlow_Timer != undefined do (
    try(VertexFlow_Timer.Stop())catch()
    try(dotNet.removeAllEventHandlers VertexFlow_Timer)catch()
    try(VertexFlow_Timer.Dispose())catch()
    VertexFlow_Timer = undefined
)

if (maxVersion())[1] < VF_MIN_MAX_MAJOR then (
    VertexFlow_LogMsg "ERR_MAX_VERSION_UNSUPPORTED: 3ds Max 2022 or newer is required" level:"ERROR"
) else if not (VF_InitJson()) then (
    -- JSON backend проверяется до запуска Timer. Раньше listener
    -- сообщал "started", даже если среда .NET не могла загрузить официальный
    -- System.Web serializer; первое задание затем оставалось без ответа.
    -- Явная ошибка не маскирует несовместимость среды под ожидание задания.
    VertexFlow_LogMsg "ERR_JSON_BACKEND_UNAVAILABLE: System.Web JSON backend is unavailable" level:"ERROR"
) else (
    VertexFlow_Timer = dotNetObject "System.Windows.Forms.Timer"
    VertexFlow_Timer.interval = 1000
    dotNet.addEventHandler VertexFlow_Timer "Tick" VertexFlow_ProcessTask
    VertexFlow_Timer.Start()
    VertexFlow_LogMsg "Transactional bridge listener started"
    -- Listener показывает фактический канал обмена. Это позволяет
    -- сразу диагностировать расхождение Temp-путей без ручного поиска по диску.
    VertexFlow_LogMsg ("Task channel: " + VF_TASK_FILE)
)

macroScript VertexFlow_UI
category:"Vertex Flow"
buttonText:"Vertex Flow Console"
toolTip:"Open Vertex Flow Console"
(
    on execute do if VertexFlow_OpenUI != undefined do VertexFlow_OpenUI()
)
