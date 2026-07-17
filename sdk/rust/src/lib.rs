wit_bindgen::generate!({
    path: "../wit",
    world: "module",
    generate_all,
});

/// Canonical language facade for values carried by the byte-only Scene ABI.
pub mod value {
    use serde_json::{Value, json};

    pub fn null() -> Value { json!({"t": "null"}) }
    pub fn boolean(value: bool) -> Value { json!({"t": "bool", "v": value}) }
    pub fn integer(value: i64) -> Value { json!({"t": "i64", "v": value.to_string()}) }
    pub fn float(value: f64) -> Result<Value, &'static str> {
        value.is_finite().then(|| json!({"t": "f64", "v": value})).ok_or("non_finite_float")
    }
    pub fn string(value: &str) -> Value { json!({"t": "string", "v": value}) }
    pub fn bytes(value: &[u8]) -> Value { json!({"t": "bytes", "v": base64(value)}) }
    pub fn array(value: Vec<Value>) -> Value { json!({"t": "array", "v": value}) }
    pub fn map(mut value: Vec<(&str, Value)>) -> Value {
        value.sort_by(|left, right| left.0.cmp(right.0));
        json!({"t": "map", "v": value})
    }
    pub fn math(tag: &str, value: &[f64], size: usize) -> Result<Value, &'static str> {
        if value.len() != size || value.iter().any(|item| !item.is_finite()) {
            return Err("malformed_math");
        }
        Ok(json!({"t": tag, "v": value}))
    }
    pub fn color(value: [f64; 4]) -> Result<Value, &'static str> {
        let value = value.map(|item| (item as f32) as f64);
        math("color", &value, 4)
    }

    fn base64(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let a = chunk[0];
            let b = *chunk.get(1).unwrap_or(&0);
            let c = *chunk.get(2).unwrap_or(&0);
            output.push(TABLE[(a >> 2) as usize] as char);
            output.push(TABLE[(((a & 3) << 4) | (b >> 4)) as usize] as char);
            output.push(if chunk.len() > 1 { TABLE[(((b & 15) << 2) | (c >> 6)) as usize] as char } else { '=' });
            output.push(if chunk.len() > 2 { TABLE[(c & 63) as usize] as char } else { '=' });
        }
        output
    }
}

struct ConformanceComponent;

impl Guest for ConformanceComponent {
    fn create() -> i32 {
        vrweb::core::host::log_code(71);
        1
    }

    fn mount(instance: i32) -> i32 {
        vrweb::core::host::log_code(if instance == 1 { 72 } else { -72 });
        0
    }

    fn event(instance: i32, envelope: Vec<u8>) -> i32 {
        let root_bytes = vrweb::scene::host::query(0, br#"{"op":"root"}"#).unwrap();
        let root = core::str::from_utf8(&root_bytes)
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let mutation = format!(
            r#"{{"op":"set","handle":"{root}","property":"visible","value":{{"t":"bool","v":false}}}}"#
        );
        vrweb::scene::host::mutate(1, mutation.as_bytes()).unwrap();
        vrweb::scene::host::commit(1).unwrap();
        vrweb::state::host::command(
            br#"{"key":"light","command":"set","value":true}"#,
        )
        .unwrap();
        let light = vrweb::state::host::read("light").unwrap();
        vrweb::core::host::log_code(if instance == 1
            && envelope.first() == Some(&b'{')
            && light == b"true"
        {
            73
        } else {
            -73
        });
        0
    }

    fn unmount(instance: i32) -> i32 {
        vrweb::core::host::log_code(if instance == 1 { 74 } else { -74 });
        0
    }
}

export!(ConformanceComponent);

#[cfg(test)]
mod tests {
    use super::value;
    use serde_json::{Value, from_str};
    use std::collections::HashMap;

    #[test]
    fn canonical_values_match_language_neutral_golden_vectors() {
        let mut actual = HashMap::<&str, Value>::new();
        actual.insert("null", value::null());
        actual.insert("bool", value::boolean(true));
        actual.insert("i64", value::integer(42));
        actual.insert("f64", value::float(3.5).unwrap());
        actual.insert("string", value::string("VRWeb ✓"));
        actual.insert("bytes", value::bytes(&[0, 1, 2, 255]));
        actual.insert("array", value::array(vec![value::boolean(true), value::integer(7)]));
        actual.insert("map", value::map(vec![("b", value::string("two")), ("a", value::integer(1))]));
        for (name, tag, values) in [
            ("vec2", "vec2", vec![1., 2.]),
            ("vec3", "vec3", vec![1., 2., 3.]),
            ("vec4", "vec4", vec![1., 2., 3., 4.]),
            ("quat", "quat", vec![0., 0., 0., 1.]),
            ("basis", "basis", vec![1., 0., 0., 0., 1., 0., 0., 0., 1.]),
            ("transform3d", "transform3d", vec![1., 0., 0., 0., 1., 0., 0., 0., 1., 4., 5., 6.]),
        ] {
            actual.insert(name, value::math(tag, &values, values.len()).unwrap());
        }
        actual.insert("color", value::color([0.1, 0.2, 0.3, 0.4]).unwrap());
        let golden: Vec<Value> = from_str(include_str!("../../../spec/value-codec-golden.json")).unwrap();
        for fixture in golden {
            let name = fixture["name"].as_str().unwrap();
            assert_eq!(actual[name], fixture["wire"], "{name}");
        }
    }
}
