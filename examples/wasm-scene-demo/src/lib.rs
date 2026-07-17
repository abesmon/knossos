use serde_json::{Value, json};

wit_bindgen::generate!({
    path: "../../sdk/wit",
    world: "module",
    generate_all,
});

struct SceneDemo;

fn scene_query(request: Value) -> Value {
    let payload = serde_json::to_vec(&request).expect("serialize Scene query");
    let response = vrweb::scene::host::query(0, &payload).expect("Scene query");
    serde_json::from_slice(&response).expect("decode Scene query result")
}

fn scene_mutate(transaction: u64, command: Value) {
    let payload = serde_json::to_vec(&command).expect("serialize Scene mutation");
    vrweb::scene::host::mutate(transaction, &payload).expect("Scene mutation");
}

fn scene_commit(transaction: u64) -> Value {
    let response = vrweb::scene::host::commit(transaction).expect("Scene commit");
    serde_json::from_slice(&response).expect("decode Scene commit result")
}

fn encoded_string(value: &str) -> Value {
    json!({"t": "string", "v": value})
}

fn encoded_vec3(x: f64, y: f64, z: f64) -> Value {
    json!({"t": "vec3", "v": [x, y, z]})
}

impl Guest for SceneDemo {
    fn create() -> i32 {
        let root = scene_query(json!({"op": "root"}))
            .as_u64()
            .expect("root handle");
        let mesh = scene_query(json!({"op": "create_resource", "class": "BoxMesh"}))
            .as_u64()
            .expect("BoxMesh handle");

        let create_transaction = 1;
        scene_mutate(
            create_transaction,
            json!({
                "op": "create",
                "token": "cube",
                "class": "MeshInstance3D",
                "parent": root.to_string(),
                "initial": {"position": encoded_vec3(0.0, 0.55, -3.0)}
            }),
        );
        scene_mutate(
            create_transaction,
            json!({
                "op": "create",
                "token": "caption",
                "class": "Label3D",
                "parent": root.to_string(),
                "initial": {
                    "text": encoded_string("CREATED BY A SANDBOXED WASM COMPONENT"),
                    "position": encoded_vec3(0.0, 1.8, -3.0)
                }
            }),
        );
        scene_mutate(
            create_transaction,
            json!({
                "op": "create",
                "token": "light",
                "class": "OmniLight3D",
                "parent": root.to_string(),
                "initial": {"position": encoded_vec3(0.0, 3.0, -1.5)}
            }),
        );
        let created = scene_commit(create_transaction);
        let cube = created["created"]["cube"]
            .as_u64()
            .expect("created cube handle");

        let resource_transaction = 2;
        scene_mutate(
            resource_transaction,
            json!({
                "op": "set_resource",
                "handle": cube.to_string(),
                "property": "mesh",
                "resource": mesh.to_string()
            }),
        );
        scene_commit(resource_transaction);
        vrweb::core::host::log_code(1001);
        1
    }

    fn mount(_instance: i32) -> i32 {
        0
    }

    fn event(_instance: i32, _envelope: Vec<u8>) -> i32 {
        0
    }

    fn unmount(_instance: i32) -> i32 {
        0
    }
}

export!(SceneDemo);
