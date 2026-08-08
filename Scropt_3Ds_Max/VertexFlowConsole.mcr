macroScript VertexFlow_UI
category:"Vertex Flow"
internalCategory:"Vertex Flow"
buttonText:"Vertex Flow Console"
toolTip:"Open Vertex Flow Console"
silentErrors:false
autoUndoEnabled:false
(
    on execute do
    (
        if ::VertexFlow_OpenUI != undefined then
            ::VertexFlow_OpenUI()
        else
            messageBox "Vertex Flow listener is not loaded. Restart 3ds Max after installing the integration." title:"Vertex Flow"
    )
)
