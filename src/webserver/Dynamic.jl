import UUIDs: uuid1


"Will hold all 'response handlers': functions that respond to a WebSocket request from the client. These are defined in `src/webserver/Dynamic.jl`."
const responses = Dict{Symbol,Function}()

responses[:connect] = function response_connect(session::ServerSession, body, notebook = nothing; initiator::Union{Initiator,Missing}=missing)
    putclientupdates!(session, initiator, UpdateMessage(:👋, Dict(
        :notebook_exists => (notebook !== nothing),
        :options => session.options,
        :version_info => Dict(
            :pluto => PLUTO_VERSION_STR,
            :julia => JULIA_VERSION_STR,
        ),
        # :notebook => notebook === nothing ? nothing : notebook_to_js(notebook),
    ), nothing, nothing, initiator))
end

responses[:ping] = function response_ping(session::ServerSession, body, notebook = nothing; initiator::Union{Initiator,Missing}=missing)
    putclientupdates!(session, initiator, UpdateMessage(:pong, Dict(), nothing, nothing, initiator))
end

responses[:run_multiple_cells] = function response_run_multiple_cells(session::ServerSession, body, notebook::Notebook; initiator::Union{Initiator,Missing}=missing)
    uuids = UUID.(body["cells"])
    cells = map(uuids) do uuid
        notebook.cells_dict[uuid]
    end

    for cell in cells
        cell.queued = true
    end
    send_notebook_changes!(NotebookRequest(session::ServerSession, notebook::Notebook, body, initiator))

    # save=true fixes the issue where "Submit all changes" or `Ctrl+S` has no effect.
    update_save_run!(session, notebook, cells; run_async=true, save=true)
end

responses[:get_all_notebooks] = function response_get_all_notebooks(session::ServerSession, body, notebook = nothing; initiator::Union{Initiator,Missing}=missing)
    putplutoupdates!(session, clientupdate_notebook_list(session.notebooks, initiator=initiator))
end

responses[:interrupt_all] = function response_interrupt_all(session::ServerSession, body, notebook::Notebook; initiator::Union{Initiator,Missing}=missing)
    success = WorkspaceManager.interrupt_workspace((session, notebook))
    # TODO: notify user whether interrupt was successful (i.e. whether they are using a `ProcessWorkspace`)
end

responses[:shutdown_notebook] = function response_shutdown_notebook(session::ServerSession, body, notebook::Notebook; initiator::Union{Initiator,Missing}=missing)
    SessionActions.shutdown(session, notebook; keep_in_session=body["keep_in_session"])
end


responses[:reshow_cell] = function response_reshow_cell(session::ServerSession, body, notebook::Notebook; initiator::Union{Initiator,Missing}=missing)
    cell = let
        cell_id = UUID(body["cell_id"])
        notebook.cells_dict[cell_id]
    end
    run = WorkspaceManager.format_fetch_in_workspace((session, notebook), cell.cell_id, ends_with_semicolon(cell.code), (parse(PlutoRunner.ObjectID, body["objectid"], base=16), convert(Int64, body["dim"])))
    set_output!(cell, run)
    # send to all clients, why not
    send_notebook_changes!(NotebookRequest(session, notebook, body, initiator))
end

# UPDATE STUFF

Base.@kwdef struct NotebookRequest
    session::ServerSession
    notebook::Notebook
    message::Any=nothing
    initiator::Union{Initiator,Nothing,Missing}=nothing
end

# Yeah I am including a Pluto Notebook!!
module Firebasey include("./FirebaseySimple.jl") end

# Base.@kwdef struct DiffableCellInputState
#     cell_id::UUID
#     code::String
#     code_folded::Bool
# end
# Base.@kwdef struct DiffableCellOutput
#     last_run_timestamp
#     persist_js_state
#     mime
#     body
#     rootassignee
# end
# Base.@kwdef struct DiffableCellResultState
#     cell_id::UUID
#     queued::Bool
#     running::Bool
#     errored::Bool
#     runtime
#     output::Union{Nothing,DiffableCellOutput}
# end
# Base.@kwdef struct DiffableNotebook
#     notebook_id::UUID
#     path::AbstractString
#     in_temp_dir::Bool
#     shortpath::AbstractString
#     cells_dict::Dict{UUID,DiffableCellInputState}
#     cell_results::Dict{UUID,DiffableCellResultState}
#     cell_order::Array{UUID}
#     bonds::Dict{Symbol,Any}
# end

# MsgPack.msgpack_type(::Type{DiffableCellInputState}) = MsgPack.StructType()
# MsgPack.msgpack_type(::Type{DiffableCellOutput}) = MsgPack.StructType()
# MsgPack.msgpack_type(::Type{DiffableCellResultState}) = MsgPack.StructType()
# MsgPack.msgpack_type(::Type{DiffableNotebook}) = MsgPack.StructType()

# Firebasey.diff(o1::DiffableNotebook, o2::DiffableNotebook) = Firebasey.diff(Firebasey.Deep(o1), Firebasey.Deep(o2))
# Firebasey.diff(o1::DiffableCellInputState, o2::DiffableCellInputState) = Firebasey.diff(Firebasey.Deep(o1), Firebasey.Deep(o2))
# Firebasey.diff(o1::DiffableCellOutput, o2::DiffableCellOutput) = Firebasey.diff(Firebasey.Deep(o1), Firebasey.Deep(o2))
# Firebasey.diff(o1::DiffableCellResultState, o2::DiffableCellResultState) = Firebasey.diff(Firebasey.Deep(o1), Firebasey.Deep(o2))

# function notebook_to_js(notebook::Notebook)
#     return DiffableNotebook(
#         notebook_id = notebook.notebook_id,
#         path = notebook.path,
#         in_temp_dir = startswith(notebook.path, new_notebooks_directory()),
#         shortpath = basename(notebook.path),
#         cells_dict = Dict(map(collect(notebook.cells_dict)) do (id, cell)
#             id => DiffableCellInputState(
#                 cell_id = cell.cell_id,
#                 code = cell.code,
#                 code_folded = cell.code_folded,
#             )
#         end),
#         cell_results = Dict(map(collect(notebook.cells_dict)) do (id, cell)
#             id => DiffableCellResultState(
#                 cell_id = cell.cell_id,
#                 queued = cell.queued,
#                 running = cell.running,
#                 errored = cell.errored,
#                 runtime = ismissing(cell.runtime) ? nothing : cell.runtime,
#                 output = DiffableCellOutput(                
#                     last_run_timestamp = cell.last_run_timestamp,
#                     persist_js_state = cell.persist_js_state,
#                     mime = cell.repr_mime,
#                     body = cell.output_repr,
#                     rootassignee = cell.rootassignee,
#                 ),
#             )
#         end),
#         cell_order = notebook.cell_order,
#         bonds = Dict(notebook.bonds),     
#     )
# end


function notebook_to_js(notebook::Notebook)
    Dict{String,Any}(
        "notebook_id" => notebook.notebook_id,
        "path" => notebook.path,
        "in_temp_dir" => startswith(notebook.path, new_notebooks_directory()),
        "shortpath" => basename(notebook.path),
        "cell_inputs" => Dict{UUID,Dict{String,Any}}(
            id => Dict{String,Any}(
                "cell_id" => cell.cell_id,
                "code" => cell.code,
                "code_folded" => cell.code_folded,
            )
        for (id, cell) in notebook.cells_dict),
        "cell_results" => Dict{UUID,Dict{String,Any}}(
            id => Dict{String,Any}(
                "cell_id" => cell.cell_id,
                "queued" => cell.queued,
                "running" => cell.running,
                "errored" => cell.errored,
                "runtime" => ismissing(cell.runtime) ? nothing : cell.runtime,
                "output" => Dict(                
                    "last_run_timestamp" => cell.last_run_timestamp,
                    "persist_js_state" => cell.persist_js_state,
                    "mime" => cell.repr_mime,
                    "body" => cell.output_repr,
                    "rootassignee" => cell.rootassignee,
                ),
            )
        for (id, cell) in notebook.cells_dict),
        "cell_order" => notebook.cell_order,
        "bonds" => Dict{String,Dict{String,Any}}(
            String(key) => Dict("value" => bondvalue.value)
        for (key, bondvalue) in notebook.bonds),
    )
end

const current_state_for_clients = WeakKeyDict{ClientSession,Any}()
function send_notebook_changes!(request::NotebookRequest; response::Any=nothing)
    notebook_dict = notebook_to_js(request.notebook)
    for (_, client) in request.session.connected_clients
        if client.connected_notebook !== nothing && client.connected_notebook.notebook_id == request.notebook.notebook_id
            current_dict = get(current_state_for_clients, client, :empty)
            patches = Firebasey.diff(current_dict, notebook_dict)
            patches_as_dicts::Array{Dict} = patches
            current_state_for_clients[client] = deepcopy(notebook_dict)

            # Make sure we do send a confirmation to the client who made the request, even without changes
            is_response = request.initiator !== nothing && client == request.initiator.client

            if length(patches) != 0 || is_response
                initiator = request.initiator === nothing ? missing : request.initiator
                response = Dict(
                    :patches => patches_as_dicts,
                    :response => is_response ? response : nothing
                )
                putclientupdates!(client, UpdateMessage(:notebook_diff, response, request.notebook, nothing, initiator))
            end
        end
    end
end



function convert_jsonpatch(::Type{Firebasey.JSONPatch}, patch_dict::Dict)
	if patch_dict["op"] == "add"
		Firebasey.AddPatch(patch_dict["path"], patch_dict["value"])
	elseif patch_dict["op"] == "remove"
		Firebasey.RemovePatch(patch_dict["path"])
	elseif patch_dict["op"] == "replace"
		Firebasey.ReplacePatch(patch_dict["path"], patch_dict["value"])
	else
		throw(ArgumentError("Unknown operation :$(patch_dict["op"]) in Dict to JSONPatch conversion"))
	end
end

struct Wildcard end
function trigger_resolver(anything, path, values=[])
	(value=anything, matches=values, rest=path)
end
function trigger_resolver(resolvers::Dict, path, values=[])
	if length(path) == 0
		throw(BoundsError("resolver path ends at Dict with keys $(keys(resolver))"))
	end
	
	segment = path[firstindex(path)]
	rest = path[firstindex(path)+1:lastindex(path)]
	for (key, resolver) in resolvers
		if key isa Wildcard
			continue
		end
		if key == segment
			return trigger_resolver(resolver, rest, values)
		end
	end
	
	if haskey(resolvers, Wildcard())
		return trigger_resolver(resolvers[Wildcard()], rest, (values..., segment))
    else
        throw(BoundsError("failed to match path $(path), possible keys $(keys(resolver))"))
	end
end

@enum Changed CodeChanged FileChanged
const no_changes = Changed[]

# to support push!(x, y...) # with y = []
Base.push!(x::Set{Changed}) = x

const effects_of_changed_state = Dict(
    "path" => function(; request::NotebookRequest, patch::Firebasey.ReplacePatch)
        newpath = tamepath(patch.value)
        # SessionActions.move(request.session, request.notebook, newpath)

        if isfile(newpath)
            throw(UserError("File exists already - you need to delete the old file manually."))
        else
            move_notebook!(request.notebook, newpath)
            putplutoupdates!(request.session, clientupdate_notebook_list(request.session.notebooks))
            WorkspaceManager.cd_workspace((request.session, request.notebook), newpath)
        end
        no_changes
    end,
    "in_temp_dir" => function(; _...) no_changes end,
    "cell_inputs" => Dict(
        Wildcard() => function(cell_id, rest; request::NotebookRequest, patch::Firebasey.JSONPatch)
            Firebasey.update!(request.notebook, patch)

            if length(rest) == 0
                [CodeChanged, FileChanged]
            elseif length(rest) == 1 && Symbol(rest[1]) == :code
                request.notebook.cells_dict[UUID(cell_id)].parsedcode = nothing
                [CodeChanged, FileChanged]
            else
                [FileChanged]
            end
        end,
    ),
    "cell_order" => function(; request::NotebookRequest, patch::Firebasey.ReplacePatch)
        Firebasey.update!(request.notebook, patch)
        # request.notebook.cell_order = patch.value
        [FileChanged]
    end,
    "bonds" => Dict(
        Wildcard() => function(name; request::NotebookRequest, patch::Firebasey.JSONPatch)
            name = Symbol(name)
            Firebasey.update!(request.notebook, patch)
            @async refresh_bond(
                session=request.session,
                notebook=request.notebook,
                name=name,
                is_first_value=patch isa Firebasey.AddPatch
            )
            # [BondChanged]
            no_changes
        end,
    )
)

function update_notebook(request::NotebookRequest)
    try
        notebook = request.notebook
        patches = (convert_jsonpatch(Firebasey.JSONPatch, update) for update in request.message["updates"])

        if length(patches) == 0
            send_notebook_changes!(request)
            return nothing
        end

        if !haskey(current_state_for_clients, request.initiator.client)
            throw(ErrorException("Updating without having a first version of the notebook??"))
        end

        # TODO Immutable ??
        for patch in patches
            Firebasey.update!(current_state_for_clients[request.initiator.client], patch)
        end

        changes = Set{Changed}()

        for patch in patches
            (mutator, matches, rest) = trigger_resolver(effects_of_changed_state, patch.path)
            
            current_changes = if length(rest) == 0 && applicable(mutator, matches...)
                mutator(matches...; request=request, patch=patch)
            else
                mutator(matches..., rest; request=request, patch=patch)
            end

            push!(changes, current_changes...)
        end

        # if CodeChanged ∈ changes
        #     update_caches!(notebook, cells)
        #     old = notebook.topology
        #     new = notebook.topology = updated_topology(old, notebook, cells)
        # end

        # If CodeChanged ∈ changes, then the client will also send a request like run_multiple_cells, which will trigger a file save _before_ running the cells.
        # In the future, we should get rid of that request, and save the file here. For now, we don't save the file here, to prevent unnecessary file IO.
        # (You can put a log in save_notebook to track how often the file is saved)
        if FileChanged ∈ changes && CodeChanged ∉ changes
            save_notebook(notebook)
        end
    
        send_notebook_changes!(request; response=Dict(:you_okay => :👍))    
    catch ex
        @error "Update notebook failed"  request.message["updates"] exception=(ex, stacktrace(catch_backtrace()))
        response = Dict(
            :you_okay => :👎,
            :why_not => sprint(showerror, ex),
            :should_i_tell_the_user => ex isa SessionActions.UserError,
        )
        send_notebook_changes!(request; response=response)
    end
end

responses[:update_notebook] = function response_update_notebook(session::ServerSession, body, notebook::Notebook; initiator::Union{Initiator,Missing}=missing)
    update_notebook(NotebookRequest(session=session, message=body, notebook=notebook, initiator=initiator))
end

function refresh_bond(; session::ServerSession, notebook::Notebook, name::Symbol, is_first_value::Bool=false)
    bound_sym = name
    new_value = notebook.bonds[name].value

    variable_exists = is_assigned_anywhere(notebook, notebook.topology, bound_sym)
    if !variable_exists
        # a bond was set while the cell is in limbo state
        # we don't need to do anything
        return
    end

    # TODO: Not checking for any dependents now
    # any_dependents = is_referenced_anywhere(notebook, notebook.topology, bound_sym)

    # fix for https://github.com/fonsp/Pluto.jl/issues/275
    # if `Base.get` was defined to give an initial value (read more about this in the Interactivity sample notebook), then we want to skip the first value sent back from the bond. (if `Base.get` was not defined, then the variable has value `missing`)
    # Check if the variable does not already have that value.
    # because if the initial value is already set, then we don't want to run dependent cells again.
    eq_tester = :(try !ismissing($bound_sym) && ($bound_sym == $new_value) catch; false end) # not just a === comparison because JS might send back the same value but with a different type (Float64 becomes Int64 in JS when it's an integer.)
    if is_first_value && WorkspaceManager.eval_fetch_in_workspace((session, notebook), eq_tester)
        return
    end
        
    function custom_deletion_hook((session, notebook)::Tuple{ServerSession,Notebook}, to_delete_vars::Set{Symbol}, funcs_to_delete::Set{Tuple{UUID,FunctionName}}, to_reimport::Set{Expr}; to_run::AbstractVector{Cell})
        push!(to_delete_vars, bound_sym) # also delete the bound symbol
        WorkspaceManager.delete_vars((session, notebook), to_delete_vars, funcs_to_delete, to_reimport)
        WorkspaceManager.eval_in_workspace((session, notebook), :($(bound_sym) = $(new_value)))
    end
    to_reeval = where_referenced(notebook, notebook.topology, Set{Symbol}([bound_sym]))

    update_save_run!(session, notebook, to_reeval; deletion_hook=custom_deletion_hook, save=false, persist_js_state=true)
end