fn main() {
    #[cfg(feature = "gui")]
    slint_build::compile("src/ui.slint").expect("slint ui compile");
}
