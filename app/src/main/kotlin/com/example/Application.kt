package com.example

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationStopped
import io.ktor.server.application.install
import io.ktor.server.application.log
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.path
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.pingPeriod
import io.ktor.server.websocket.timeout
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import org.slf4j.event.Level
import java.sql.SQLException
import java.util.concurrent.atomic.AtomicLong
import kotlin.time.Duration.Companion.seconds

@Serializable
data class Note(val id: Long, val text: String, val createdAt: String)

@Serializable
data class NewNote(val text: String)

private const val SCHEMA = """
    CREATE TABLE IF NOT EXISTS notes (
        id BIGSERIAL PRIMARY KEY,
        text TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
"""

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8080
    embeddedServer(Netty, port = port, host = "0.0.0.0", module = Application::module).start(wait = true)
}

/**
 * Builds a small pool sized for a 1 GB node; the app starts even if Postgres is not up yet.
 */
fun dataSource(): HikariDataSource = HikariDataSource(
    HikariConfig().apply {
        jdbcUrl = System.getenv("DB_URL") ?: "jdbc:postgresql://localhost:5432/ktor"
        username = System.getenv("DB_USER") ?: "ktor"
        password = System.getenv("DB_PASSWORD") ?: "ktor"
        maximumPoolSize = 5
        minimumIdle = 1
        connectionTimeout = 5_000
        idleTimeout = 120_000
        maxLifetime = 1_800_000
        initializationFailTimeout = -1
        poolName = "ktor-poc"
    }
)

fun Application.module() {
    val db = dataSource()
    monitor.subscribe(ApplicationStopped) { db.close() }

    install(ContentNegotiation) { json() }
    install(CallLogging) {
        level = Level.INFO
        filter { it.request.path() !in setOf("/health", "/ready") }
    }
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            call.application.log.error("unhandled error", cause)
            call.respond(HttpStatusCode.InternalServerError, mapOf("error" to (cause.message ?: "internal error")))
        }
    }
    install(WebSockets) {
        pingPeriod = 15.seconds
        timeout = 30.seconds
        maxFrameSize = 64 * 1024L
        masking = false
    }

    // retry schema creation in the background until Postgres accepts connections
    launch(Dispatchers.IO) {
        var backoffMs = 1_000L
        while (isActive) {
            try {
                db.connection.use { conn -> conn.createStatement().use { it.execute(SCHEMA) } }
                log.info("schema ready")
                break
            } catch (e: SQLException) {
                log.warn("database not ready (${e.message}), retrying in ${backoffMs}ms")
                delay(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(30_000)
            }
        }
    }

    val chat = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val sessionIds = AtomicLong()

    routing {
        get("/") {
            call.respond(mapOf("service" to "ktor-poc", "endpoints" to "/health /ready /api/notes /ws/echo /ws/chat"))
        }

        get("/health") { call.respond(mapOf("status" to "up")) }

        get("/ready") {
            val ok = withContext(Dispatchers.IO) {
                runCatching { db.connection.use { it.isValid(2) } }.getOrDefault(false)
            }
            if (ok) call.respond(mapOf("status" to "ready"))
            else call.respond(HttpStatusCode.ServiceUnavailable, mapOf("status" to "database unavailable"))
        }

        route("/api/notes") {
            get {
                val notes = withContext(Dispatchers.IO) {
                    db.connection.use { conn ->
                        conn.prepareStatement("SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT 100").use { st ->
                            st.executeQuery().use { rs ->
                                buildList {
                                    while (rs.next()) add(Note(rs.getLong(1), rs.getString(2), rs.getString(3)))
                                }
                            }
                        }
                    }
                }
                call.respond(notes)
            }

            post {
                val input = call.receive<NewNote>()
                if (input.text.isBlank()) {
                    call.respond(HttpStatusCode.BadRequest, mapOf("error" to "text must not be blank"))
                    return@post
                }
                val note = withContext(Dispatchers.IO) {
                    db.connection.use { conn ->
                        conn.prepareStatement("INSERT INTO notes(text) VALUES (?) RETURNING id, text, created_at").use { st ->
                            st.setString(1, input.text)
                            st.executeQuery().use { rs ->
                                rs.next()
                                Note(rs.getLong(1), rs.getString(2), rs.getString(3))
                            }
                        }
                    }
                }
                call.respond(HttpStatusCode.Created, note)
            }
        }

        webSocket("/ws/echo") {
            for (frame in incoming) {
                if (frame is Frame.Text) send(Frame.Text("echo: ${frame.readText()}"))
            }
        }

        // every message is broadcast to all connected sessions
        webSocket("/ws/chat") {
            val id = sessionIds.incrementAndGet()
            // undispatched so the subscription exists before the join message is emitted
            val fanOut = launch(start = CoroutineStart.UNDISPATCHED) { chat.collect { send(Frame.Text(it)) } }
            chat.emit("* user-$id joined")
            try {
                for (frame in incoming) {
                    if (frame is Frame.Text) chat.emit("user-$id: ${frame.readText()}")
                }
            } finally {
                fanOut.cancel()
                chat.tryEmit("* user-$id left")
            }
        }
    }
}
