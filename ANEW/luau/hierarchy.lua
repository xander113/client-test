local Hierarchy = {maxDepth=20}

function Hierarchy.isScript(node)
    return node.kind=="script" or node.kind=="local"
end

function Hierarchy.index(place)
    local nodes,children={},{}
    local function add(list)
        for _,node in ipairs(list) do
            nodes[node.id]=node
            local parent=node.parent or ""
            local branch=children[parent] or {}
            branch[#branch+1]=node
            children[parent]=branch
        end
    end
    add(place.objects)
    add(place.scripts)
    return nodes,children
end

function Hierarchy.owner(nodes,node)
    while node and Hierarchy.isScript(node) do node=nodes[node.parent] end
    return node
end

function Hierarchy.canParent(nodes,node,parent)
    local depth=0
    while parent do
        if parent==node.id or depth>=Hierarchy.maxDepth then return false end
        local ancestor=nodes[parent]
        if not ancestor or (not Hierarchy.isScript(node) and Hierarchy.isScript(ancestor)) then return false end
        parent=ancestor.parent
        depth=depth+1
    end
    return true,depth
end

function Hierarchy.branch(children,id)
    local result={}
    local function visit(node,depth)
        for _,child in ipairs(children[node] or {}) do
            result[#result+1]={node=child,depth=depth}
            visit(child.id,depth+1)
        end
    end
    visit(id,1)
    return result
end

return Hierarchy
