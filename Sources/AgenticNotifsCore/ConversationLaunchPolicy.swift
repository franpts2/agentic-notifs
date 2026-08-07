public enum ConversationLaunchPolicy {
    public static func zedArguments(projectPath: String) -> [String] {
        // Match an open workspace exactly, but never reuse an unrelated window.
        ["--classic", projectPath]
    }
}
