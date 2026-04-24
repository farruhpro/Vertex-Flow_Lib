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

-- ИСПРАВЛЕНИЕ: Вынесли рекурсивную функцию в глобальную область, 
-- чтобы компилятор MAXScript больше не сходил с ума от вложенности.
fn VertexFlow_CollectMatsAndMaps m arr = (
    if m == undefined do return false
    if findItem arr m > 0 do return false
    append arr m
    
    if hasProperty m "getNumSubMtls" do (
        local numMtls = getNumSubMtls m
        for i = 1 to numMtls do VertexFlow_CollectMatsAndMaps (getSubMtl m i) arr
    )
    if hasProperty m "getNumSubTexmaps" do (
        local numMaps = getNumSubTexmaps m
        for i = 1 to numMaps do VertexFlow_CollectMatsAndMaps (getSubTexmap m i) arr
    )
)

-- === РЕКУРСИВНЫЙ РЕЛИНКЕР ТОЛЬКО ДЛЯ ВЫДЕЛЕННЫХ ОБЪЕКТОВ ===
fn VertexFlow_RelinkTargetedNodes texPath targetNodes = (
    if texPath == undefined or texPath == "" or targetNodes == undefined or targetNodes.count == 0 do return false
    
    local normTexPath = substituteString texPath "/" "\\"
    if substring normTexPath normTexPath.count 1 == "\\" do (
        normTexPath = substring normTexPath 1 (normTexPath.count - 1)
    )
    
    local relinkedCount = 0
    local propsToCheck = #("filename", "HDRIMapName", "mapName", "ies_file", "iesFile", "file", "proxy_file")
    
    local allMatsAndMaps = #()
    
    -- Собираем материалы импортированных объектов + сами объекты (для Proxy/IES)
    for obj in targetNodes do (
        if hasProperty obj "material" and obj.material != undefined do VertexFlow_CollectMatsAndMaps obj.material allMatsAndMaps
        appendIfUnique allMatsAndMaps obj
    )
    
    -- Применяем пути
    for item in allMatsAndMaps do (
        for p in propsToCheck do (
            if hasProperty item p do (
                local oldPath = getProperty item p
                if oldPath != undefined and classOf oldPath == String and oldPath != "" do (
                    local fName = filenameFromPath oldPath
                    if fName != "" do (
                        local newPath = normTexPath + "\\" + fName
                        if (toLower oldPath) != (toLower newPath) do (
                            if doesFileExist newPath then (
                                setProperty item p newPath
                                relinkedCount += 1
                            )
                        )
                    )
                )
            )
        )
    )
    
    try(freeSceneBitmaps())catch()
    try(ATSOps.Refresh())catch()
    
    if relinkedCount > 0 then (
        VertexFlow_LogMsg ("Relinked " + (relinkedCount as string) + " paths for imported model.")
    ) else (
        VertexFlow_LogMsg ("No matching textures found for relinking.")
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
                local currentMaxPath = maxFilePath + maxFileName
                
                if currentMaxPath == "" then (
                    VertexFlow_LogMsg "Scene is not saved!" isError:true
                    try(deleteFile taskFile)catch()
                ) else if (VertexFlow_NormalizePath currentMaxPath) == (VertexFlow_NormalizePath pPath) then (
                    
                    try(deleteFile taskFile)catch()
                    
                    local fileNameFull = filenameFromPath mPath
                    VertexFlow_LogMsg ("Importing: " + fileNameFull)
                    
                    if doesFileExist mPath then (
                        try (
                            local ext = toLower (getFilenameType mPath)
                            local importSuccess = false
                            
                            clearSelection()
                            local preImportObjects = objects as array
                            
                            if ext == ".max" then (
                                local mergeResult = mergeMAXFile mPath #mergeDups #select quiet:true
                                
                                if mergeResult == true then (
                                    importSuccess = true
                                ) else (
                                    local detectedYear = ""
                                    local fileVerInfo = undefined
                                    try ( fileVerInfo = getMaxFileVersion mPath ) catch()
                                    
                                    if fileVerInfo != undefined and classOf fileVerInfo == Array and fileVerInfo.count > 0 then (
                                        detectedYear = ((fileVerInfo[1] / 1000) + 1998) as string
                                    ) else (
                                        try (
                                            local fs = (dotNetClass "System.IO.File").OpenRead mPath
                                            local br = dotNetObject "System.IO.BinaryReader" fs
                                            
                                            local len = fs.Length
                                            local firstChunkSize = if len < 100000 then len else 100000
                                            local firstBytes = br.ReadBytes firstChunkSize
                                            
                                            local lastBytes = #()
                                            if len > 100000 do (
                                                fs.Seek -100000 (dotNetClass "System.IO.SeekOrigin").End
                                                lastBytes = br.ReadBytes 100000
                                            )
                                            br.Close()
                                            fs.Close()
                                            
                                            local headerStr = ""
                                            for b in firstBytes do ( if b >= 32 and b <= 126 do headerStr += bit.intAsChar b )
                                            for b in lastBytes do ( if b >= 32 and b <= 126 do headerStr += bit.intAsChar b )
                                            
                                            local idx = findString headerStr "3ds Max "
                                            if idx != undefined then (
                                                detectedYear = substring headerStr (idx + 8) 4
                                            ) else (
                                                detectedYear = "Unknown Newer"
                                            )
                                        ) catch ( detectedYear = "Unknown Newer" )
                                    )
                                    
                                    local curVerInfo = maxVersion()
                                    local curYear = ((curVerInfo[1] / 1000) + 1998) as string
                                    VertexFlow_LogMsg ("Import Error: Model is 3ds Max " + detectedYear + ". You use " + curYear + ".") isError:true
                                )
                            ) else if ext == ".fbx" or ext == ".obj" then (
                                local importResult = importFile mPath #noPrompt
                                if importResult == true then (
                                    importSuccess = true
                                ) else (
                                    VertexFlow_LogMsg ("Format Error: Failed to import " + ext) isError:true
                                )
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
                                    VertexFlow_RelinkTargetedNodes tPath importedNodes
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
