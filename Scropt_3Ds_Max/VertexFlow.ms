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

-- === ИДЕАЛЬНЫЙ РЕЛИНКЕР ТОЛЬКО ДЛЯ ИМПОРТИРОВАННОЙ МОДЕЛИ ===
fn VertexFlow_RelinkAssets texPath targetNodes = (
    if texPath == undefined or texPath == "" or targetNodes == undefined or targetNodes.count == 0 do return false
    
    -- Нативная нормализация пути (исправляет проблему пустых путей в Asset Tracking)
    local safeTexPath = pathConfig.normalizePath texPath
    local propsToCheck = #("filename", "HDRIMapName", "mapName", "ies_file", "iesFile", "file", "proxy_file")
    local relinkedCount = 0
    
    local allMatsAndMaps = #()
    local nodesToProcess = #()
    
    -- Собираем объекты и их корневые материалы
    for obj in targetNodes do (
        appendIfUnique nodesToProcess obj
        if hasProperty obj "material" and obj.material != undefined do appendIfUnique allMatsAndMaps obj.material
    )
    
    -- БЕЗОПАСНЫЙ ИТЕРАТИВНЫЙ ОБХОД МАТЕРИАЛОВ (Без рекурсий, без крашей)
    local i = 1
    while i <= allMatsAndMaps.count do (
        local currentItem = allMatsAndMaps[i]
        
        if hasProperty currentItem "getNumSubMtls" do (
            local num = getNumSubMtls currentItem
            for j = 1 to num do (
                local sm = getSubMtl currentItem j
                if sm != undefined do appendIfUnique allMatsAndMaps sm
            )
        )
        
        if hasProperty currentItem "getNumSubTexmaps" do (
            local num = getNumSubTexmaps currentItem
            for j = 1 to num do (
                local st = getSubTexmap currentItem j
                if st != undefined do appendIfUnique allMatsAndMaps st
            )
        )
        i += 1
    )
    
    -- Назначаем пути строго через нативный pathConfig.appendPath
    for item in allMatsAndMaps do (
        for p in propsToCheck do (
            if hasProperty item p do (
                try (
                    local oldPath = getProperty item p
                    if oldPath != undefined and classOf oldPath == String and oldPath != "" do (
                        local fName = filenameFromPath oldPath
                        if fName != "" do (
                            local newPath = pathConfig.appendPath safeTexPath fName
                            if (toLower oldPath) != (toLower newPath) do (
                                setProperty item p newPath
                                relinkedCount += 1
                            )
                        )
                    )
                ) catch()
            )
        )
    )
    
    -- То же самое для геометрии (для Proxy и IES)
    for item in nodesToProcess do (
        for p in propsToCheck do (
            if hasProperty item p do (
                try (
                    local oldPath = getProperty item p
                    if oldPath != undefined and classOf oldPath == String and oldPath != "" do (
                        local fName = filenameFromPath oldPath
                        if fName != "" do (
                            local newPath = pathConfig.appendPath safeTexPath fName
                            if (toLower oldPath) != (toLower newPath) do (
                                setProperty item p newPath
                                relinkedCount += 1
                            )
                        )
                    )
                ) catch()
            )
        )
    )
    
    try(freeSceneBitmaps())catch()
    try(ATSOps.Refresh())catch()
    
    if relinkedCount > 0 then (
        VertexFlow_LogMsg ("Relinked " + (relinkedCount as string) + " paths for imported model.")
    ) else (
        VertexFlow_LogMsg ("No matching textures found for relinking in imported model.")
    )
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
                -- Нормализуем пути, чтобы 3ds Max не сходил с ума от прямых слешей
                local safeMaxPath = pathConfig.normalizePath (maxFilePath + maxFileName)
                local safePPath = pathConfig.normalizePath pPath
                local safeMPath = pathConfig.normalizePath mPath
                
                if safeMaxPath == "" then (
                    VertexFlow_LogMsg "Scene is not saved!" isError:true
                    try(deleteFile taskFile)catch()
                ) else if (toLower safeMaxPath) == (toLower safePPath) then (
                    
                    try(deleteFile taskFile)catch()
                    
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
                                    -- ЧТЕНИЕ ВЕРСИИ НОВОЙ МОДЕЛИ (Работает 100% благодаря safeMPath)
                                    local fileVerInfo = undefined
                                    try ( fileVerInfo = getMaxFileVersion safeMPath ) catch()
                                    
                                    if fileVerInfo != undefined and classOf fileVerInfo == Array and fileVerInfo.count > 0 then (
                                        local fileYear = ((fileVerInfo[1] / 1000) + 1998) as string
                                        local curYear = (((maxVersion())[1] / 1000) + 1998) as string
                                        VertexFlow_LogMsg ("Import Error: Model is 3ds Max " + fileYear + ". You use " + curYear + ".") isError:true
                                    ) else (
                                        -- Запасной вариант, если файл вообще поврежден
                                        local curYear = (((maxVersion())[1] / 1000) + 1998) as string
                                        VertexFlow_LogMsg ("Import Error: Model version is unsupported (Newer than " + curYear + " or corrupted).") isError:true
                                    )
                                )
                            ) else if ext == ".fbx" or ext == ".obj" then (
                                local impResult = importFile safeMPath #noPrompt
                                if impResult == true do importSuccess = true
                            ) else (
                                VertexFlow_LogMsg ("Format " + ext + " not supported!") isError:true
                                return false
                            )
                            
                            if importSuccess then (
                                local importedNodes = getCurrentSelection() as array
                                if importedNodes.count == 0 then (
                                    local newNodes = #()
                                    for obj in objects do (
                                        if findItem preImportObjects obj == 0 do append newNodes obj
                                    )
                                    if newNodes.count > 0 do (
                                        select newNodes
                                        importedNodes = newNodes
                                    )
                                )
                                
                                if tPath != "" and importedNodes.count > 0 do (
                                    VertexFlow_RelinkAssets tPath importedNodes
                                )
                                
                                if importedNodes.count > 0 do max zoomext sel
                                VertexFlow_LogMsg "Success! Model added." isError:false
                            )
                        ) catch (
                            local err = getCurrentException()
                            VertexFlow_LogMsg ("CRASH: " + err) isError:true
                        )
                    ) else (
                        VertexFlow_LogMsg "File not found on disk!" isError:true
                    )
                )
            ) else (
                try(deleteFile taskFile)catch()
                VertexFlow_LogMsg "Invalid JSON deleted." isError:true
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
