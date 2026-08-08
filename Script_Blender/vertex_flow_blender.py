"""Мост Vertex Flow для Blender.

Мост импортирует модель в уже открытый проект, изменяет только ресурсы текущего
импорта и никогда не сохраняет проект, не копирует текстуры и не создаёт архив.
Переназначение путей выполняется только при ``relink_textures == True`` — это
общая настройка Vertex Flow для всех поддерживаемых DCC.

"""

bl_info = {
    "name": "Vertex Flow Integration",
    "author": "Farrukh Gulamzhanov",
    # Искусственный major 2, появившийся вместе с protocol v2,
    # удалён. До первого релиза сохраняется исходная ветка интеграции 1.1.
    "version": (1, 1, 0),
    "blender": (3, 6, 0),
    "location": "View3D > Sidebar > Vertex Flow",
    "description": "Transactional Vertex Flow model import bridge",
    "doc_url": "https://vertexflow.farrukh.pro",
    "tracker_url": "https://vertexflow.farrukh.pro",
    "category": "Import-Export",
}

import json
import os
import tempfile
import time
import traceback
from collections import deque
from pathlib import Path

import bpy
from bpy.app.handlers import persistent


MIN_BLENDER_VERSION = (3, 6, 0)
MAX_TASK_BYTES = 4 * 1024 * 1024
MAX_TASK_AGE_MS = 10 * 60 * 1000
TASK_FILE = Path(tempfile.gettempdir()) / "vertex_flow_task.json"
SUPPORTED_EXTENSIONS = {".blend", ".fbx", ".obj"}
ID_COLLECTION_NAMES = (
    "objects",
    "collections",
    "materials",
    "node_groups",
    "images",
    "textures",
    "meshes",
    "curves",
    "metaballs",
    "armatures",
    "lattices",
    "cameras",
    "lights",
    "actions",
    "shape_keys",
    "fonts",
    "volumes",
    "pointclouds",
    "hair_curves",
)
ROLLBACK_ORDER = (
    "objects",
    "collections",
    "meshes",
    "curves",
    "metaballs",
    "armatures",
    "lattices",
    "cameras",
    "lights",
    "shape_keys",
    "fonts",
    "volumes",
    "pointclouds",
    "hair_curves",
    "materials",
    "node_groups",
    "textures",
    "images",
    "actions",
)

_VF_BUSY = False
_VF_PROCESSED_JOB_IDS = deque(maxlen=128)
_VF_PREVIOUS_LISTENER = globals().get("_VF_REGISTERED_LISTENER")
_VF_PREVIOUS_LOAD_HANDLER = globals().get("_VF_REGISTERED_LOAD_HANDLER")


class BridgeError(RuntimeError):
    """Стабильная ошибка моста с машинным кодом для Rust и UI."""

    def __init__(self, code, message, details=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


class VF_Logs:
    """Короткий журнал для N-panel Blender и системной консоли."""

    messages = []

    @classmethod
    def add(cls, message, level="INFO"):
        # UI и системная консоль получают одну диагностическую запись;
        # ошибки больше не исчезают внутри широких ``except: pass``.
        text = "[{0}] {1}".format(level, str(message))
        print("[Vertex Flow] " + text)
        cls.messages.append(text)
        if len(cls.messages) > 30:
            del cls.messages[0 : len(cls.messages) - 30]


class VIEW3D_PT_vertex_flow(bpy.types.Panel):
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Vertex Flow"
    bl_label = "Vertex Flow Status"

    def draw(self, _context):
        layout = self.layout
        row = layout.row()
        row.label(text="Listener: active", icon="RADIOBUT_ON")
        layout.separator()
        layout.label(text="Recent events:")
        box = layout.box()
        if not VF_Logs.messages:
            box.label(text="Waiting for tasks...", icon="INFO")
        else:
            for message in reversed(VF_Logs.messages[-10:]):
                box.label(text=message[:180])
        layout.operator("vf.clear_logs", text="Clear log", icon="TRASH")


class VF_OT_clear_logs(bpy.types.Operator):
    bl_idname = "vf.clear_logs"
    bl_label = "Clear Vertex Flow Logs"

    def execute(self, _context):
        VF_Logs.messages.clear()
        return {"FINISHED"}


def _atomic_write_json(path, payload, job_id):
    # Ответ сначала пишется во временный файл рядом, сбрасывается
    # через fsync и атомарно заменяет основной. Rust не прочитает половину JSON.
    safe_job_id = "".join(ch for ch in str(job_id) if ch.isalnum() or ch in "-_")[:96]
    # job_id всегда обязателен и генерируется Rust, поэтому имя
    # временного файла больше не содержит legacy-заглушку.
    temporary = path.with_name(".{0}.{1}.tmp".format(path.name, safe_job_id))
    try:
        with open(temporary, "x", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _write_result(task, status, code, message, warnings=None, details=None):
    payload = {
        # В единственном текущем контракте ответ связывается с
        # заданием только обязательным job_id; protocol_version удалён.
        "job_id": task["job_id"],
        "status": status,
        "code": code,
        "message": message,
        "warnings": list(warnings or []),
        "details": details or {},
    }
    _atomic_write_json(TASK_FILE, payload, task["job_id"])


def _canonical(path):
    return os.path.normcase(os.path.abspath(os.path.normpath(os.fspath(path))))


def _same_file(left, right):
    try:
        return os.path.samefile(left, right)
    except (OSError, ValueError):
        return _canonical(left) == _canonical(right)


def _read_task():
    try:
        stat = TASK_FILE.stat()
    except FileNotFoundError:
        return None
    if stat.st_size <= 0 or stat.st_size > MAX_TASK_BYTES:
        raise BridgeError("ERR_TASK_SIZE", "Task file has an invalid size")
    try:
        with open(TASK_FILE, "r", encoding="utf-8") as stream:
            payload = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        # Rust publishes tasks atomically. A malformed visible file is therefore
        # a protocol error, not an invitation to import from partially read data.
        raise BridgeError("ERR_TASK_JSON", "Task JSON is incomplete or invalid", {"error": str(error)})
    if not isinstance(payload, dict):
        raise BridgeError("ERR_TASK_SCHEMA", "Task root must be a JSON object")
    return payload


def _required_string(task, name, max_length=32767):
    value = task.get(name)
    if not isinstance(value, str) or not value.strip() or len(value) > max_length:
        raise BridgeError("ERR_TASK_SCHEMA", "Invalid field: " + name, {"field": name})
    if any(ord(character) < 32 for character in value):
        raise BridgeError("ERR_TASK_SCHEMA", "Control character in field: " + name, {"field": name})
    return value


def _validate_task(task):
    status = task.get("status")
    if status != "pending":
        return None

    # Искусственное версионирование и задание без job_id удалены.
    # До релиза мост принимает ровно один текущий контракт.
    job_id = task.get("job_id")
    if not isinstance(job_id, str) or not job_id or len(job_id) > 128:
        raise BridgeError("ERR_TASK_SCHEMA", "A valid job_id is required")
    if job_id in _VF_PROCESSED_JOB_IDS:
        return None

    # Время создания обязательно для каждого pending-задания;
    # ветка без timestamp больше не может обойти проверку зависшего файла.
    created_at_ms = task.get("created_at_ms")
    if not isinstance(created_at_ms, int):
        raise BridgeError("ERR_TASK_SCHEMA", "created_at_ms must be an integer")
    age = int(time.time() * 1000) - created_at_ms
    if age > MAX_TASK_AGE_MS or age < -60_000:
        raise BridgeError("ERR_TASK_STALE", "Task timestamp is stale or in the future")

    model_path = Path(_required_string(task, "model_path"))
    project_path = Path(_required_string(task, "project_path"))
    textures_path_raw = task.get("textures_path", "")
    if not isinstance(textures_path_raw, str):
        raise BridgeError("ERR_TASK_SCHEMA", "textures_path must be a string")
    textures_path = Path(textures_path_raw) if textures_path_raw else None
    # Несмотря на историческое имя настройки в UI, это общий
    # переключатель для 3ds Max и Blender. Мост принимает только JSON boolean.
    relink_textures = task.get("relink_textures")
    if not isinstance(relink_textures, bool):
        raise BridgeError("ERR_TASK_SCHEMA", "relink_textures must be a boolean")

    if not model_path.is_absolute() or not project_path.is_absolute():
        raise BridgeError("ERR_PATH_NOT_ABSOLUTE", "Model and project paths must be absolute")
    if not model_path.is_file():
        raise BridgeError("ERR_MODEL_NOT_FOUND", "Model file does not exist", {"path": str(model_path)})
    extension = model_path.suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise BridgeError("ERR_UNSUPPORTED_FORMAT", "Unsupported model format", {"ext": extension})
    if not bpy.data.filepath:
        raise BridgeError("ERR_SCENE_NOT_SAVED", "The current Blender project must be saved first")
    if not _same_file(bpy.data.filepath, project_path):
        raise BridgeError("ERR_PROJECT_MISMATCH", "The open Blender project does not match the task")
    # Папка текстур нужна только для фактического переназначения.
    # При выключенном тумблере модель импортируется без изменения путей, поэтому
    # пустой textures_path не должен блокировать безопасный импорт.
    if relink_textures:
        if textures_path is None or not textures_path.is_absolute() or not textures_path.is_dir():
            raise BridgeError("ERR_TEXTURES_DIR", "textures_path must be an existing absolute directory")

    normalized = dict(task)
    normalized.update(
        {
            "job_id": job_id,
            "model_path": str(model_path),
            "project_path": str(project_path),
            "textures_path": str(textures_path) if textures_path else "",
        }
    )
    return normalized


class SceneSnapshot:
    """Снимок старой сцены для определения новых ресурсов и проверки защиты."""

    def __init__(self, context):
        # Ресурсы текущего импорта определяются по разнице наборов ID,
        # а не по выделению, active collection, именам или побочным эффектам importer.
        self.ids = {}
        for name in ID_COLLECTION_NAMES:
            collection = getattr(bpy.data, name, None)
            if collection is not None:
                self.ids[name] = set(collection)
        self.all_ids = set().union(*self.ids.values()) if self.ids else set()
        self.objects = set(bpy.data.objects)
        self.image_paths = {image: image.filepath for image in bpy.data.images}
        self.object_data = {obj: obj.data for obj in self.objects}
        self.object_transforms = {obj: obj.matrix_world.copy() for obj in self.objects}
        self.object_parents = {obj: obj.parent for obj in self.objects}
        self.object_materials = {
            obj: tuple(slot.material for slot in obj.material_slots) for obj in self.objects
        }
        self.collection_objects = {
            collection: tuple(collection.objects)
            for collection in self.ids.get("collections", set())
            if collection is not context.scene.collection
        }
        self.collection_children = {
            collection: tuple(collection.children)
            for collection in self.ids.get("collections", set())
            if collection is not context.scene.collection
        }
        self.scene_world = context.scene.world
        self.scene_compositor = context.scene.node_tree
        self.scene_use_nodes = context.scene.use_nodes
        self.modifier_groups = {}
        for obj in self.objects:
            for modifier in obj.modifiers:
                if hasattr(modifier, "node_group"):
                    self.modifier_groups[(obj, modifier.name)] = modifier.node_group
        self.selected = tuple(context.selected_objects)
        self.active = context.view_layer.objects.active
        self.active_mode = self.active.mode if self.active is not None else "OBJECT"
        self.active_layer_collection = context.view_layer.active_layer_collection

    def new_ids(self, name):
        collection = getattr(bpy.data, name, None)
        if collection is None:
            return set()
        return set(collection) - self.ids.get(name, set())

    def verify_existing_scene(self, context):
        # [ИСПРАВЛЕНО]: context передаётся явно. В прежнем варианте ссылка на
        # несуществующую локальную переменную могла вызвать NameError уже после
        # импорта и ошибочно перевести успешную операцию в rollback.
        current_images = set(bpy.data.images)
        current_objects = set(bpy.data.objects)
        for image, old_path in self.image_paths.items():
            if image not in current_images:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "A pre-existing image was removed")
            if image.filepath != old_path:
                raise BridgeError(
                    "ERR_SCENE_PROTECTION_VIOLATION",
                    "An image that existed before import was modified",
                    {"image": image.name},
                )
        for obj, old_data in self.object_data.items():
            if obj not in current_objects:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "A pre-existing object was removed")
            if obj.data is not old_data:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "Pre-existing object data changed")
            if obj.parent is not self.object_parents[obj] or obj.matrix_world != self.object_transforms[obj]:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "Pre-existing object transform/parent changed")
            current_materials = tuple(slot.material for slot in obj.material_slots)
            if current_materials != self.object_materials[obj]:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "Pre-existing material assignment changed")
        for (obj, modifier_name), old_group in self.modifier_groups.items():
            modifier = obj.modifiers.get(modifier_name) if obj in current_objects else None
            if modifier is None or modifier.node_group is not old_group:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "Pre-existing Geometry Nodes changed")
        current_collections = set(bpy.data.collections)
        for collection, old_objects in self.collection_objects.items():
            if collection not in current_collections:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "A pre-existing collection was removed")
            if tuple(collection.objects) != old_objects or tuple(collection.children) != self.collection_children[collection]:
                raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "A pre-existing collection was modified")
        if (
            context.scene.world is not self.scene_world
            or context.scene.node_tree is not self.scene_compositor
            or context.scene.use_nodes != self.scene_use_nodes
        ):
            raise BridgeError("ERR_SCENE_PROTECTION_VIOLATION", "World or Compositor was changed")

    def restore_existing_scene(self, context, warnings):
        # Если штатный importer частично изменил старую сцену,
        # rollback восстанавливает снимок до проверки удаления новых ID.
        current_objects = set(bpy.data.objects)
        for image, old_path in self.image_paths.items():
            try:
                if image in bpy.data.images:
                    image.filepath = old_path
                else:
                    warnings.append("ROLLBACK_OLD_IMAGE_MISSING: " + image.name)
            except Exception as error:
                warnings.append("ROLLBACK_OLD_IMAGE_RESTORE_FAILED: " + str(error))
        for obj in self.objects:
            if obj not in current_objects:
                warnings.append("ROLLBACK_OLD_OBJECT_MISSING: " + obj.name)
                continue
            try:
                obj.parent = self.object_parents[obj]
                obj.matrix_world = self.object_transforms[obj]
                obj.data = self.object_data[obj]
                for index, material in enumerate(self.object_materials[obj]):
                    if index < len(obj.material_slots):
                        obj.material_slots[index].material = material
            except Exception as error:
                warnings.append("ROLLBACK_OLD_OBJECT_RESTORE_FAILED: " + str(error))
        for (obj, modifier_name), old_group in self.modifier_groups.items():
            try:
                modifier = obj.modifiers.get(modifier_name)
                if modifier is not None:
                    modifier.node_group = old_group
            except Exception as error:
                warnings.append("ROLLBACK_OLD_MODIFIER_RESTORE_FAILED: " + str(error))
        current_collections = set(bpy.data.collections)
        for collection, old_objects in self.collection_objects.items():
            if collection not in current_collections:
                warnings.append("ROLLBACK_OLD_COLLECTION_MISSING: " + collection.name)
                continue
            try:
                for obj in old_objects:
                    if obj in current_objects and collection.objects.get(obj.name) is None:
                        collection.objects.link(obj)
                for obj in tuple(collection.objects):
                    if obj in self.objects and obj not in old_objects:
                        collection.objects.unlink(obj)
                old_children = self.collection_children[collection]
                for child in old_children:
                    if child in current_collections and collection.children.get(child.name) is None:
                        collection.children.link(child)
                for child in tuple(collection.children):
                    if child in self.ids.get("collections", set()) and child not in old_children:
                        collection.children.unlink(child)
            except Exception as error:
                warnings.append("ROLLBACK_OLD_COLLECTION_RESTORE_FAILED: " + str(error))
        try:
            context.scene.world = self.scene_world
            context.scene.use_nodes = self.scene_use_nodes
            if context.scene.node_tree is not self.scene_compositor:
                warnings.append("ROLLBACK_COMPOSITOR_RESTORE_UNAVAILABLE")
        except Exception as error:
            warnings.append("ROLLBACK_SCENE_SETTINGS_RESTORE_FAILED: " + str(error))


def _restore_user_state(snapshot, context, warnings=None, strict=False):
    # Операторы импорта могут менять mode, selection и active collection.
    # После success или rollback временное состояние пользователя восстанавливается.
    failures = []
    try:
        active_now = context.view_layer.objects.active
        if active_now is not None and active_now.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
    except Exception as error:
        failures.append("Could not leave temporary mode: " + str(error))
    for obj in tuple(context.selected_objects):
        try:
            obj.select_set(False)
        except ReferenceError:
            pass
    for obj in snapshot.selected:
        if obj.name in bpy.data.objects:
            obj.select_set(True)
    if snapshot.active is not None and snapshot.active.name in bpy.data.objects:
        context.view_layer.objects.active = snapshot.active
    try:
        context.view_layer.active_layer_collection = snapshot.active_layer_collection
    except (ReferenceError, TypeError):
        failures.append("Could not restore active collection")
    if snapshot.active is not None and snapshot.active.name in bpy.data.objects and snapshot.active_mode != "OBJECT":
        try:
            bpy.ops.object.mode_set(mode=snapshot.active_mode)
        except Exception as error:
            failures.append("Could not restore mode {0}: {1}".format(snapshot.active_mode, error))
    for failure in failures:
        VF_Logs.add(failure, "WARNING")
        if warnings is not None:
            warnings.append("WARN_USER_STATE_RESTORE_FAILED: " + failure)
    if failures and strict:
        raise BridgeError("ERR_USER_STATE_RESTORE", "Blender user state could not be restored")


def _prepare_operator_context(context):
    active = context.view_layer.objects.active
    if active is not None and active.mode != "OBJECT":
        if not bpy.ops.object.mode_set.poll():
            raise BridgeError("ERR_UNSAFE_CONTEXT", "Cannot switch Blender to Object Mode for import")
        bpy.ops.object.mode_set(mode="OBJECT")
    for obj in tuple(context.selected_objects):
        obj.select_set(False)


def _find_layer_collection(layer_collection, target):
    if layer_collection.collection == target:
        return layer_collection
    for child in layer_collection.children:
        found = _find_layer_collection(child, target)
        if found is not None:
            return found
    return None


def _make_import_collection(context, job_id):
    # job_id обязателен, поэтому временное имя по текущему времени
    # больше не подменяет отсутствующий идентификатор задания.
    name = "VertexFlow_" + job_id[:48]
    collection = bpy.data.collections.new(name)
    context.scene.collection.children.link(collection)
    context.view_layer.update()
    layer_collection = _find_layer_collection(context.view_layer.layer_collection, collection)
    if layer_collection is not None:
        context.view_layer.active_layer_collection = layer_collection
    return collection


def _isolate_imported_collections(context, snapshot, target_collection, imported_objects):
    # Даже если importer проигнорировал active collection, новые
    # объекты/коллекции удаляются из старых ветвей и помещаются под job-collection.
    old_collections = set(snapshot.ids.get("collections", set()))
    old_collections.add(context.scene.collection)
    for obj in imported_objects:
        for collection in tuple(obj.users_collection):
            if collection in old_collections:
                collection.objects.unlink(obj)
        if not obj.users_collection:
            target_collection.objects.link(obj)
        if obj.parent in snapshot.objects:
            raise BridgeError("ERR_SHARED_SCENE_DEPENDENCY", "Imported object depends on a pre-existing parent")
    new_collections = snapshot.new_ids("collections") - {target_collection}
    for old_collection in old_collections:
        for child in tuple(old_collection.children):
            if child in new_collections:
                old_collection.children.unlink(child)
                if target_collection.children.get(child.name) is None:
                    target_collection.children.link(child)


def _import_blend(model_path, target_collection):
    # .blend всегда использует локальный Append (link=False), поэтому
    # импортированный ассет не сохраняет зависимость от исходного .blend.
    with bpy.data.libraries.load(str(model_path), link=False) as (data_from, data_to):
        data_to.objects = list(data_from.objects)
    imported = []
    for obj in data_to.objects:
        if obj is not None:
            target_collection.objects.link(obj)
            imported.append(obj)
    return imported


def _import_fbx(model_path):
    operator = getattr(getattr(bpy.ops, "import_scene", None), "fbx", None)
    if operator is None:
        raise BridgeError("ERR_IMPORTER_UNAVAILABLE", "The bundled FBX importer is unavailable")
    result = operator(filepath=str(model_path))
    if "FINISHED" not in result:
        raise BridgeError("ERR_IMPORT_FAILED", "Blender FBX importer did not finish", {"result": list(result)})


def _import_obj(model_path):
    # Эта развилка относится к поддерживаемым Blender 3.6 и 4.x/5.x,
    # а не к старым версиям протокола Vertex Flow.
    modern = getattr(getattr(bpy.ops, "wm", None), "obj_import", None)
    blender_36_operator = getattr(getattr(bpy.ops, "import_scene", None), "obj", None)
    if bpy.app.version >= (4, 0, 0) and modern is not None:
        result = modern(filepath=str(model_path))
    elif blender_36_operator is not None:
        result = blender_36_operator(filepath=str(model_path))
    elif modern is not None:
        result = modern(filepath=str(model_path))
    else:
        raise BridgeError("ERR_IMPORTER_UNAVAILABLE", "No built-in OBJ importer is available")
    if "FINISHED" not in result:
        raise BridgeError("ERR_IMPORT_FAILED", "Blender OBJ importer did not finish", {"result": list(result)})


class ResourceIsolator:
    """Копирует старые или общие ID-блоки до изменения ветки импорта."""

    def __init__(self, snapshot, warnings):
        self.snapshot = snapshot
        self.warnings = warnings
        self.material_cache = {}
        self.group_cache = {}
        self.image_cache = {}
        self.texture_cache = {}
        self.visited_trees = set()
        self.used_images = set()

    def _copy_if_old(self, block, old_collection, cache, kind):
        if block is None:
            return None
        if block in cache:
            return cache[block]
        must_copy = block in self.snapshot.ids.get(old_collection, set()) or block.library is not None
        if must_copy:
            try:
                copied = block.copy()
            except Exception as error:
                raise BridgeError(
                    "ERR_SHARED_DATABLOCK_ISOLATION",
                    "Cannot localize shared {0}".format(kind),
                    {"name": block.name, "error": str(error)},
                )
            if copied.library is not None:
                raise BridgeError("ERR_LINKED_DATABLOCK", "Copied data-block is still library-linked")
        else:
            copied = block
        cache[block] = copied
        return copied

    def localize_image(self, image):
        localized = self._copy_if_old(image, "images", self.image_cache, "image")
        if localized is not None:
            self.used_images.add(localized)
        return localized

    def localize_texture(self, texture):
        localized = self._copy_if_old(texture, "textures", self.texture_cache, "texture")
        if localized is not None and hasattr(localized, "image") and localized.image is not None:
            localized.image = self.localize_image(localized.image)
        return localized

    def localize_material(self, material):
        localized = self._copy_if_old(material, "materials", self.material_cache, "material")
        if localized is None:
            return None
        if localized.node_tree is not None:
            self.walk_node_tree(localized.node_tree)
        return localized

    def localize_group(self, group):
        localized = self._copy_if_old(group, "node_groups", self.group_cache, "node group")
        if localized is not None:
            self.walk_node_tree(localized)
        return localized

    def walk_node_tree(self, node_tree):
        if node_tree is None or node_tree in self.visited_trees:
            return
        self.visited_trees.add(node_tree)
        for node in node_tree.nodes:
            if hasattr(node, "node_tree") and node.node_tree is not None:
                node.node_tree = self.localize_group(node.node_tree)
            if hasattr(node, "image") and node.image is not None:
                node.image = self.localize_image(node.image)
            if hasattr(node, "material") and node.material is not None:
                node.material = self.localize_material(node.material)
            if hasattr(node, "texture") and node.texture is not None:
                node.texture = self.localize_texture(node.texture)

    def process_object(self, obj):
        if obj.library is not None:
            raise BridgeError("ERR_LINKED_DATABLOCK", "Imported object is still library-linked")
        data = obj.data
        if data is not None and (data in self.snapshot.all_ids or data.library is not None):
            try:
                obj.data = data.copy()
            except Exception as error:
                raise BridgeError("ERR_SHARED_DATABLOCK_ISOLATION", "Cannot copy shared object data", {"error": str(error)})
        for slot in obj.material_slots:
            if slot.material is not None:
                slot.material = self.localize_material(slot.material)
        for modifier in obj.modifiers:
            if hasattr(modifier, "node_group") and modifier.node_group is not None:
                modifier.node_group = self.localize_group(modifier.node_group)
            if hasattr(modifier, "texture") and modifier.texture is not None:
                modifier.texture = self.localize_texture(modifier.texture)
        object_data = obj.data
        if object_data is not None and hasattr(object_data, "node_tree"):
            self.walk_node_tree(object_data.node_tree)


class TextureResolver:
    """Находит скопированную текстуру по уникальному имени в textures_path."""

    def __init__(self, task, warnings):
        # Rust уже скопировал все текстуры в одну плоскую папку с
        # гарантированно уникальными именами. Индексы source->target и обход
        # всей папки больше не создаются.
        self.warnings = warnings
        self.root = Path(task["textures_path"])

    def resolve(self, image):
        raw_path = image.filepath or ""
        if not raw_path:
            return None
        # Нормализуем оба разделителя только для извлечения имени,
        # чтобы Windows-путь из модели корректно работал и в Blender на macOS.
        filename = raw_path.replace("\\", "/").rsplit("/", 1)[-1]
        target = self.root / filename
        if filename and target.is_file():
            return str(target)
        self.warnings.append("WARN_TEXTURE_UNMAPPED: " + image.name)
        return None


def _is_packed(image):
    if getattr(image, "packed_file", None) is not None:
        return True
    return bool(getattr(image, "packed_files", ()))


def _relink_images(task, images, warnings, journal):
    # [ИСПРАВЛЕНО]: Общий переключатель одинаково действует в Blender и 3ds Max.
    # При false не создаём resolver и не читаем папку текстур: пути изображений
    # текущего импорта остаются ровно такими, какими их вернул Blender importer.
    if not task["relink_textures"]:
        return 0

    resolver = TextureResolver(task, warnings)
    changed = 0
    for image in sorted(images, key=lambda value: value.name):
        source_type = getattr(image, "source", "FILE")
        if source_type not in {"FILE", "SEQUENCE", "TILED"}:
            continue
        if _is_packed(image):
            warnings.append("WARN_PACKED_IMAGE_SKIPPED: " + image.name)
            continue
        if source_type in {"SEQUENCE", "TILED"}:
            # SEQUENCE и UDIM состоят из нескольких файлов. Подмена
            # их одним basename может незаметно оставить только один кадр/тайл.
            # Без подтверждённого полного шаблона сохраняем исходный путь и
            # явно возвращаем warning — это fail-safe поведение обоих мостов.
            warning_code = (
                "WARN_SEQUENCE_REQUIRES_EXACT_PATTERN"
                if source_type == "SEQUENCE"
                else "WARN_UDIM_REQUIRES_EXACT_PATTERN"
            )
            warnings.append(warning_code + ": " + image.name)
            continue
        target = resolver.resolve(image)
        if target is None:
            continue
        if not os.path.isfile(target):
            warnings.append("WARN_TEXTURE_TARGET_MISSING: " + target)
            continue
        old_path = image.filepath
        journal.append((image, old_path))
        image.filepath = os.path.abspath(target)
        try:
            image.reload()
        except Exception as error:
            image.filepath = old_path
            raise BridgeError(
                "ERR_TEXTURE_RELOAD",
                "Blender could not reload a mapped texture",
                {"image": image.name, "error": str(error)},
            )
        if _canonical(image.filepath) != _canonical(target):
            image.filepath = old_path
            raise BridgeError("ERR_TEXTURE_VERIFY", "Texture path verification failed", {"image": image.name})
        changed += 1
    return changed


def _remove_id(collection, block):
    try:
        collection.remove(block, do_unlink=True)
    except TypeError:
        collection.remove(block)


def _rollback(snapshot, journal, context):
    warnings = []
    for image, old_path in reversed(journal):
        try:
            if image.name in bpy.data.images:
                image.filepath = old_path
        except Exception as error:
            warnings.append("ROLLBACK_IMAGE_FAILED: " + str(error))
    snapshot.restore_existing_scene(context, warnings)
    for name in ROLLBACK_ORDER:
        collection = getattr(bpy.data, name, None)
        if collection is None:
            continue
        for block in list(snapshot.new_ids(name)):
            try:
                # New objects/collections are owned by this job and may still be
                # linked to the new import collection/scene root. Other IDs with
                # remaining users are retained fail-safe because an old block may
                # have acquired a reference through a third-party import callback.
                if name not in {"objects", "collections"} and getattr(block, "users", 0) > 0:
                    warnings.append("ROLLBACK_RESOURCE_STILL_USED: {0}:{1}".format(name, block.name))
                    continue
                _remove_id(collection, block)
            except Exception as error:
                warnings.append("ROLLBACK_REMOVE_FAILED: {0}:{1}".format(name, error))
    _restore_user_state(snapshot, context, warnings=warnings)
    try:
        snapshot.verify_existing_scene(context)
    except Exception as error:
        warnings.append("ROLLBACK_SCENE_VERIFY_FAILED: " + str(error))
    return warnings


def _execute_import(task):
    if bpy.app.version < MIN_BLENDER_VERSION:
        raise BridgeError(
            "ERR_BLENDER_VERSION_UNSUPPORTED",
            "Vertex Flow requires Blender 3.6 LTS or newer",
            {"current": list(bpy.app.version)},
        )
    context = bpy.context
    snapshot = SceneSnapshot(context)
    warnings = []
    journal = []
    try:
        _prepare_operator_context(context)
        target_collection = _make_import_collection(context, task["job_id"])
        model_path = Path(task["model_path"])
        extension = model_path.suffix.lower()
        if extension == ".blend":
            _import_blend(model_path, target_collection)
        elif extension == ".fbx":
            _import_fbx(model_path)
        elif extension == ".obj":
            _import_obj(model_path)

        imported_objects = set(bpy.data.objects) - snapshot.objects
        if not imported_objects:
            raise BridgeError("ERR_NO_IMPORTED_OBJECTS", "Importer created no new objects")
        for obj in imported_objects:
            if obj.library is not None:
                raise BridgeError("ERR_LINKED_DATABLOCK", "Import left a linked object", {"object": obj.name})
        _isolate_imported_collections(context, snapshot, target_collection, imported_objects)

        isolator = ResourceIsolator(snapshot, warnings)
        for obj in sorted(imported_objects, key=lambda value: value.name):
            isolator.process_object(obj)
        relinked = _relink_images(task, isolator.used_images, warnings, journal)

        # The source scene is checked after every mutation. A violation turns the
        # whole operation into rollback instead of a false success.
        snapshot.verify_existing_scene(context)
        _restore_user_state(snapshot, context, warnings=warnings, strict=True)
        status = "completed_with_warnings" if warnings else "completed"
        return status, warnings, {
            "imported_objects": len(imported_objects),
            "used_images": len(isolator.used_images),
            "relinked_images": relinked,
            "created_materials": len(snapshot.new_ids("materials")),
            "created_node_groups": len(snapshot.new_ids("node_groups")),
        }
    except Exception as error:
        rollback_warnings = _rollback(snapshot, journal, context)
        if rollback_warnings:
            if isinstance(error, BridgeError):
                original = {"code": error.code, "message": error.message, "details": error.details}
            else:
                original = {"code": "ERR_BLENDER_INTERNAL", "message": str(error)}
            raise BridgeError(
                "ERR_ROLLBACK_FAILED",
                "Import failed and rollback was incomplete",
                {"original": original, "rollback_warnings": rollback_warnings},
            )
        if isinstance(error, BridgeError):
            error.details = dict(error.details, rollback="completed")
            raise
        raise BridgeError(
            "ERR_BLENDER_INTERNAL",
            "Unexpected Blender bridge exception",
            {"error": str(error), "traceback": traceback.format_exc(limit=8), "rollback": "completed"},
        )


def vertex_flow_listener():
    global _VF_BUSY
    if _VF_BUSY or not TASK_FILE.exists():
        return 1.0
    raw_task = {}
    try:
        raw_task = _read_task()
        if raw_task is None:
            return 1.0
        task = _validate_task(raw_task)
        if task is None:
            return 1.0
        _VF_BUSY = True
        # processing записывается тем же строгим форматом ответа,
        # поэтому Rust не принимает копию входного задания за повреждённый ответ.
        _write_result(task, "processing", None, "Blender is processing the task")
        VF_Logs.add("Import started: " + Path(task["model_path"]).name)
        status, warnings, details = _execute_import(task)
        message = "Import completed" if not warnings else "Import completed with warnings"
        _write_result(task, status, None, message, warnings, details)
        _VF_PROCESSED_JOB_IDS.append(task["job_id"])
        VF_Logs.add(message, "WARNING" if warnings else "INFO")
    except BridgeError as error:
        VF_Logs.add("{0}: {1}".format(error.code, error.message), "ERROR")
        try:
            status = "rolled_back" if error.details.get("rollback") == "completed" else "error"
            _write_result(raw_task, status, error.code, error.message, [], error.details)
        except Exception as write_error:
            VF_Logs.add("Cannot write error response: " + str(write_error), "ERROR")
    except Exception as error:
        VF_Logs.add("ERR_BRIDGE_INTERNAL: " + str(error), "ERROR")
        try:
            _write_result(
                raw_task,
                "error",
                "ERR_BRIDGE_INTERNAL",
                "Unexpected listener failure",
                [],
                {"error": str(error), "traceback": traceback.format_exc(limit=8)},
            )
        except Exception as write_error:
            VF_Logs.add("Cannot write internal error response: " + str(write_error), "ERROR")
    finally:
        _VF_BUSY = False
    return 1.0


classes = (VIEW3D_PT_vertex_flow, VF_OT_clear_logs)


@persistent
def vf_start_timer_handler(_dummy):
    if not bpy.app.timers.is_registered(vertex_flow_listener):
        bpy.app.timers.register(vertex_flow_listener, first_interval=1.0, persistent=True)


def register():
    # Ранее загруженные listener и handler удаляются явно;
    # повторный запуск .py не накапливает timers и load_post callbacks.
    if _VF_PREVIOUS_LISTENER is not None:
        try:
            if bpy.app.timers.is_registered(_VF_PREVIOUS_LISTENER):
                bpy.app.timers.unregister(_VF_PREVIOUS_LISTENER)
        except Exception as error:
            VF_Logs.add("Could not unregister old timer: " + str(error), "WARNING")
    if _VF_PREVIOUS_LOAD_HANDLER in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_VF_PREVIOUS_LOAD_HANDLER)
    for cls in classes:
        try:
            bpy.utils.register_class(cls)
        except ValueError:
            # Same class can already be registered when startup and manual install overlap.
            pass
    if vf_start_timer_handler not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(vf_start_timer_handler)
    if not bpy.app.timers.is_registered(vertex_flow_listener):
        bpy.app.timers.register(vertex_flow_listener, first_interval=1.0, persistent=True)
    globals()["_VF_REGISTERED_LISTENER"] = vertex_flow_listener
    globals()["_VF_REGISTERED_LOAD_HANDLER"] = vf_start_timer_handler
    VF_Logs.add("Bridge listener registered")


def unregister():
    if bpy.app.timers.is_registered(vertex_flow_listener):
        bpy.app.timers.unregister(vertex_flow_listener)
    if vf_start_timer_handler in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(vf_start_timer_handler)
    for cls in reversed(classes):
        try:
            bpy.utils.unregister_class(cls)
        except RuntimeError:
            pass


# Blender выполняет startup-скрипт, но не вызывает addon register()
# автоматически. Регистрация вызывается здесь и не создаёт фоновых threads.
try:
    register()
except Exception as startup_error:
    VF_Logs.add("Bridge registration failed: " + str(startup_error), "ERROR")
