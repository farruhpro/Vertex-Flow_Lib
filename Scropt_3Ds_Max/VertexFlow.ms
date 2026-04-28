-- VERTEX FLOW PLUG-IN (PRO EDITION)
-- Installation: Drag & Drop this file into the 3ds Max viewport!

(
    local startupDir = getDir #userStartupScripts
    local targetFile = startupDir + "\\VertexFlowListener.ms"
    local sourceFile = getSourceFileName()
    
    if sourceFile != undefined and (toLower sourceFile) != (toLower targetFile) do (
        try (
            deleteFile targetFile
            copyFile sourceFile targetFile
            messageBox "Vertex Flow Plug-in installed successfully!\n\nIt will start automatically in the background.\nTo open the console, press 'X' and search for 'Vertex Flow Console'." title:"Vertex Flow: Installation"
        ) catch (
            messageBox "Installation failed. Please run 3ds Max as Administrator." title:"Vertex Flow: Error"
        )
    )
)

global VertexFlow_Log = #()
global VertexFlow_UpdateUI
global VertexFlow_Timer
global VertexFlowListenerUI 
global VertexFlow_ParsedYear = "Unknown"

fn VertexFlow_PadZero num = (
    local s = num as string
    if s.count < 2 then "0" + s else s
)

fn VertexFlow_LogMsg msg isError:false = (
    local t = getLocalTime()
    local timeStr = "[" + (VertexFlow_PadZero t[5]) + ":" + (VertexFlow_PadZero t[6]) + ":" + (VertexFlow_PadZero t[7]) + "] "
    local prefix = if isError then "[ ERR ] " else "[ OK ] "
    local fullMsg = timeStr + prefix + msg
    
    insertItem fullMsg VertexFlow_Log 1
    if VertexFlow_Log.count > 50 do VertexFlow_Log.count = 50 
    if VertexFlow_UpdateUI != undefined do VertexFlow_UpdateUI()
)

fn VertexFlow_NormalizePath p = (
    if p == undefined or p == "" then return ""
    return toLower (substituteString p "\\" "/")
)

fn VertexFlow_ExtractJsonValue str key = (
    local dnStr = dotNetObject "System.String" str
    local searchKey = "\"" + key + "\""
    local p1 = dnStr.IndexOf searchKey
    if p1 == -1 do return ""
    p1 += searchKey.count
    local pStart = dnStr.IndexOf "\"" p1
    if pStart == -1 do return ""
    pStart += 1
    local pEnd = dnStr.IndexOf "\"" pStart
    if pEnd == -1 do return ""
    return dnStr.Substring pStart (pEnd - pStart)
)

-- === АЛГОРИТМ В СТИЛЕ RELINK BITMAPS ===
fn VertexFlow_RelinkAssets texPath importedNodes = (
    if texPath == undefined or texPath == "" or importedNodes.count == 0 do return false
    
    -- Очищаем путь от лишних слешей, чтобы Asset Tracking не выдавал пустые поля
    local texPathClean = trimRight (substituteString texPath "/" "\\") "\\"
    
    -- Список классов и их свойств путей (охватывает V-Ray, Corona, Standard, Proxy, IES)
    local classesToCheck = #(Bitmaptexture, VRayBitmap, CoronaBitmap, VRayHDRI, VRayProxy, CoronaProxy, VRayIES, CoronaIES)
    local propsToCheck = #("filename", "HDRIMapName", "mapName", "ies_file", "iesFile", "file", "proxy_file")
    
    local relinkedCount = 0
    
    for cls in classesToCheck do (
        try (
            -- Собираем абсолютно все текстуры этого класса в сцене
            local instances = getClassInstances cls processAllAnimatables:true
            
            for inst in instances do (
                -- ФИШКА КОЛИНА СЕННЕРА: Спрашиваем у текстуры, к каким объектам сцены она привязана
                local deps = refs.dependentNodes inst
                local isOurs = false
                
                -- Если текстура привязана хотя бы к одному объекту из нашей импортированной модели — берем ее в работу!
                for d in deps do (
                    if findItem importedNodes d > 0 do (
                        isOurs = true
                        exit
                    )
                )
                
                if isOurs do (
                    for p in propsToCheck do (
                        if hasProperty inst p do (
                            local oldPath = getProperty inst p
                            if oldPath != undefined and classOf oldPath == String and oldPath != "" do (
                                local fName = filenameFromPath oldPath
                                if fName != "" do (
                                    local newPath = texPathClean + "\\" + fName
                                    if (toLower oldPath) != (toLower newPath) do (
                                        setProperty inst p newPath
                                        relinkedCount += 1
                                    )
                                )
                            )
                        )
                    )
                )
            )
        ) catch()
    )
    
    try(freeSceneBitmaps())catch()
    try(ATSOps.Refresh())catch()
    
    if relinkedCount > 0 then (
        VertexFlow_LogMsg ("Relinked " + (relinkedCount as string) + " paths for imported model.")
    ) else (
        VertexFlow_LogMsg ("No matching textures found for relinking.")
    )
)

-- [ДОБАВЛЕНО]: Функция обратной связи для Rust. 
-- Вместо удаления файла, мы перезаписываем его с новым статусом (completed/error).
fn VertexFlow_WriteTaskResult file status msg = (
    try (
        local ioFile = dotNetClass "System.IO.File"
        local encoding = dotNetClass "System.Text.Encoding"
        local jsonStr = "{ \"status\": \"" + status + "\", \"message\": \"" + msg + "\" }"
        ioFile.WriteAllText file jsonStr encoding.UTF8
    ) catch()
)

fn VertexFlow_ProcessTask sender args = (
    local tempDir = sysInfo.tempdir
    local taskFile = tempDir + "\\vertex_flow_task.json"
    
    if getFiles taskFile != #() do (
        local fileContent = ""
        try (
            local ioFile = dotNetClass "System.IO.File"
            local encoding = dotNetClass "System.Text.Encoding"
            fileContent = ioFile.ReadAllText taskFile encoding.UTF8
        ) catch ( return false )
        
        if fileContent != "" do (
            local mPath = VertexFlow_ExtractJsonValue fileContent "model_path"
            local pPath = VertexFlow_ExtractJsonValue fileContent "project_path"
            local tPath = VertexFlow_ExtractJsonValue fileContent "textures_path" 
            
            if mPath != "" and pPath != "" then (
               local safeMaxPath = substituteString (maxFilePath + maxFileName) "/" "\\"
                local safePPath = substituteString pPath "/" "\\"
                local safeMPath = substituteString mPath "/" "\\"
                
                if safeMaxPath == "" then (
                    VertexFlow_LogMsg "Scene is not saved!" isError:true
                    -- [ИЗМЕНЕНО]: Записываем ошибку в файл, Rust сам всё очистит
                    VertexFlow_WriteTaskResult taskFile "error" "Scene is not saved"
                ) else if (toLower safeMaxPath) == (toLower safePPath) then (
                    -- [УДАЛЕНО]: try(deleteFile taskFile)catch() - Больше не удаляем файл!
                    
                    local fileNameFull = filenameFromPath safeMPath
                    VertexFlow_LogMsg ("Importing: " + fileNameFull)
                    
                    if doesFileExist safeMPath then (
                        try (
                            local ext = toLower (getFilenameType safeMPath)
                            local importSuccess = false
                            
                            clearSelection()
                            local preImportObjects = objects as array
                            
                            if ext == ".max" then (
                                local mergeResult = mergeMAXFile safeMPath #mergeDups #select quiet:true
                                
                                if mergeResult == true then (
                                    importSuccess = true
                                ) else (
                                    VertexFlow_ParsedYear = "Unknown"
                                    local pyScript = "import pymxs\n"
                                    pyScript += "try:\n"
                                    pyScript += "    with open(r'" + safeMPath + "', 'rb') as f:\n"
                                    pyScript += "        data = f.read(50000000)\n"
                                    pyScript += "        pattern = bytes([51,0,100,0,115,0,32,0,77,0,97,0,120,0,32,0,50,0,48,0])\n"
                                    pyScript += "        idx = data.find(pattern)\n"
                                    pyScript += "        if idx != -1:\n"
                                    pyScript += "            ver_bytes = data[idx:idx+24]\n"
                                    pyScript += "            ver = ver_bytes.decode('utf-16-le').replace(chr(0), '').strip()\n"
                                    pyScript += "            pymxs.runtime.VertexFlow_ParsedYear = ver.split(' ')[-1]\n"
                                    pyScript += "except Exception as e:\n"
                                    pyScript += "    pass\n"
                                    
                                    try ( python.Execute pyScript ) catch()
                                    
                                    local fileYear = VertexFlow_ParsedYear
                                    if fileYear == "Unknown" do fileYear = "Newer Version"
                                    
                                    local curYear = (((maxVersion())[1] / 1000) + 1998) as string
                                    VertexFlow_LogMsg ("Import Error: Model is 3ds Max " + fileYear + ". You use " + curYear + ".") isError:true
                                    
                                    -- [ДОБАВЛЕНО]: Сообщаем Rust, что версия не подходит
                                    VertexFlow_WriteTaskResult taskFile "error" ("Version mismatch: " + fileYear)
                                )
                            ) else if ext == ".fbx" or ext == ".obj" then (
                                local impResult = importFile safeMPath #noPrompt
                                if impResult == true do importSuccess = true
                            ) else (
                                VertexFlow_LogMsg ("Format " + ext + " not supported!") isError:true
                                -- [ДОБАВЛЕНО]: Сообщаем об ошибке формата
                                VertexFlow_WriteTaskResult taskFile "error" "Unsupported format"
                                return false
                            )
                            
                            if importSuccess then (
                                local importedNodes = getCurrentSelection() as array
                                if importedNodes.count == 0 then (
                                    local newNodes = #()
                                    for obj in objects do (
                                        if findItem preImportObjects obj == 0 do append newNodes obj
                                    )
                                    importedNodes = newNodes
                                )
                                
                                if importedNodes.count > 0 do (
                                    select importedNodes
                                    if tPath != "" do VertexFlow_RelinkAssets tPath importedNodes
                                    max zoomext sel
                                )
                                VertexFlow_LogMsg "Success! Model added." isError:false
                                
                                -- [ДОБАВЛЕНО]: Главный момент Handshake. Сообщаем Rust, что импорт завершен!
                                VertexFlow_WriteTaskResult taskFile "completed" "Success"
                            )
                        ) catch (
                            local err = getCurrentException()
                            VertexFlow_LogMsg ("CRASH: " + err) isError:true
                            -- [ДОБАВЛЕНО]: Если упал сам 3ds Max, разблокируем UI
                            VertexFlow_WriteTaskResult taskFile "error" "3ds Max Internal Crash"
                        )
                    ) else (
                        VertexFlow_LogMsg "File not found on disk!" isError:true
                        VertexFlow_WriteTaskResult taskFile "error" "File not found"
                    )
                )
            ) else (
                -- [УДАЛЕНО]: try(deleteFile taskFile)catch() - Убираем удаление при невалидном JSON
                VertexFlow_LogMsg "Invalid JSON." isError:true
                VertexFlow_WriteTaskResult taskFile "error" "Invalid JSON"
            )
        )
    )
)

try(destroyDialog VertexFlowListenerUI)catch()
rollout VertexFlowListenerUI "Vertex Flow: Console" width:350 height:320
(
    label lblStatus "Status: [ LISTENING ]" pos:[10,10] width:330
    label lblLastAction "-" pos:[10,30] width:330
    button btnToggle "Stop Listening" pos:[10,50] width:330 height:30
    button btnManual "Manual Check" pos:[10,85] width:330 height:25
    label lblLogTitle "Event Log:" pos:[10,120]
    edittext txtLog "" pos:[10,140] width:330 height:165 readOnly:true
    
    fn UpdateUI = (
        local fullText = ""
        for msg in VertexFlow_Log do fullText += msg + "\r\n"
        txtLog.text = fullText
        if VertexFlow_Log.count > 0 do lblLastAction.text = VertexFlow_Log[1]
        
        if VertexFlow_Timer != undefined and VertexFlow_Timer.Enabled then (
            lblStatus.text = "Status: [ LISTENING ]"
            btnToggle.text = "Stop Listening"
        ) else (
            lblStatus.text = "Status: [ DISABLED ]"
            btnToggle.text = "Start Listening"
        )
    )
    
    on VertexFlowListenerUI open do ( VertexFlow_UpdateUI = UpdateUI; UpdateUI() )
    on VertexFlowListenerUI close do ( VertexFlow_UpdateUI = undefined )
    
    on btnToggle pressed do (
        if VertexFlow_Timer != undefined do (
            if VertexFlow_Timer.Enabled then (
                VertexFlow_Timer.Stop()
                VertexFlow_LogMsg "Listening stopped." isError:true
            ) else (
                VertexFlow_Timer.Start()
                VertexFlow_LogMsg "Listening started." isError:false
            )
        )
    )
    on btnManual pressed do ( VertexFlow_ProcessTask undefined undefined )
)

global VertexFlow_OpenUI
fn VertexFlow_OpenUI = (
    try(destroyDialog VertexFlowListenerUI)catch()
    createDialog VertexFlowListenerUI style:#(#style_toolwindow, #style_sysmenu)
)

if VertexFlow_Timer == undefined do (
    VertexFlow_Timer = dotNetObject "System.Windows.Forms.Timer"
    VertexFlow_Timer.interval = 1000
    dotNet.addEventHandler VertexFlow_Timer "Tick" VertexFlow_ProcessTask
    VertexFlow_Timer.start()
    VertexFlow_LogMsg "Background listener started." isError:false
)

macroScript VertexFlow_UI
category:"Vertex Flow"
buttonText:"Vertex Flow Console"
toolTip:"Open Vertex Flow Console"
(
    on execute do (
        if VertexFlow_OpenUI != undefined do VertexFlow_OpenUI()
    )
)
