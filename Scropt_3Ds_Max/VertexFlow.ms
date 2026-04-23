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

-- === OMNI-DIRECTIONAL RELINKER (???????? ?????? ?????) ===
fn VertexFlow_RelinkAssets texPath = (
    if texPath == undefined or texPath == "" do return false
    
    -- ??????????? ???? ??? Windows (???????? / ?? \)
    local normTexPath = substituteString texPath "/" "\\"
    if substring normTexPath normTexPath.count 1 == "\\" do (
        normTexPath = substring normTexPath 1 (normTexPath.count - 1)
    )
    
    if not (doesFileExist normTexPath) do (
        VertexFlow_LogMsg ("Relink Error: Folder not found -> " + normTexPath) isError:true
        return false
    )
    
    local relinkedCount = 0
    -- ?????? ???? ????????? ???????, ??? ??????? ?????? ???? ? ??????
    local propsToCheck = #("filename", "HDRIMapName", "mapName", "ies_file", "iesFile", "file", "proxy_file")
    
    -- ??????????? ???????? ??? ?????? ???????, ????????? (Proxy) ? ????? (IES)
    local categories = #(textureMap.classes, GeometryClass.classes, light.classes)
    
    for cat in categories do (
        for cls in cat do (
            try (
                -- processAllAnimatables:true ?????????? ???? ?????? ???? ? ??????? ??????????
                for inst in (getClassInstances cls processAllAnimatables:true) do (
                    for p in propsToCheck do (
                        if hasProperty inst p do (
                            local oldPath = getProperty inst p
                            if oldPath != undefined and classOf oldPath == String and oldPath != "" do (
                                
                                local fName = filenameFromPath oldPath
                                local newPath = normTexPath + "\\" + fName
                                
                                -- ???? ???? ??? ?? ???????? ? ???? ??????? ?????????? ?? ?????
                                if (toLower oldPath) != (toLower newPath) do (
                                    if doesFileExist newPath then (
                                        setProperty inst p newPath
                                        relinkedCount += 1
                                    )
                                )
                            )
                        )
                    )
                )
            ) catch()
        )
    )
    
    -- ????????????? ????????? ??????? ? ??? ??????????
    try(freeSceneBitmaps())catch()
    try(ATSOps.Refresh())catch()
    
    if relinkedCount > 0 then (
        VertexFlow_LogMsg ("Relinked " + (relinkedCount as string) + " asset absolute paths.")
    ) else (
        VertexFlow_LogMsg ("No textures needed relinking or not found.")
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
            local tPath = VertexFlow_ExtractJsonValue fileContent "textures_path" -- ???????? ???? ? ?????????
            
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
                            
                            if ext == ".max" then (
                                mergeMAXFile mPath #mergeDups #select quiet:true
                                importSuccess = true
                            ) else if ext == ".fbx" or ext == ".obj" then (
                                importFile mPath #noPrompt
                                importSuccess = true
                            ) else (
                                VertexFlow_LogMsg ("Format " + ext + " not supported!") isError:true
                                return false
                            )
                            
                            if importSuccess then (
                                -- === ????? ???????????? ????? ????? ??????? ===
                                if tPath != "" do VertexFlow_RelinkAssets tPath
                                
                                max zoomext sel
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