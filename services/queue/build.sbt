ThisBuild / scalaVersion := "2.13.14"
ThisBuild / organization := "memekaruta"

lazy val root = (project in file("."))
  .settings(
    name           := "queue",
    version        := "0.1.0",
    Compile / mainClass := Some("memekaruta.queue.Main"),
    assembly / mainClass := Some("memekaruta.queue.Main"),
    assembly / assemblyJarName := "queue.jar",
  )
