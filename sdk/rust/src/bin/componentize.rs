use std::env;
use std::error::Error;
use std::fs;
use wit_component::ComponentEncoder;

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = env::args_os().skip(1);
    let input = args.next().ok_or("missing core module input path")?;
    let output = args.next().ok_or("missing component output path")?;
    if args.next().is_some() {
        return Err("expected exactly input and output paths".into());
    }
    let core_module = fs::read(input)?;
    let component = ComponentEncoder::default()
        .validate(true)
        .module(&core_module)?
        .encode()?;
    fs::write(output, component)?;
    Ok(())
}
