allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/TrustTunnel/TrustTunnelClient")
            credentials {
                // логин можно оставить пустым
                username = ""
                // читаем токен из env или gradle.properties
                password = System.getenv("GPR_KEY") ?: findProperty("GPR_KEY")?.toString().orEmpty()
            }
            authentication {
                create<BasicAuthentication>("basic")
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}