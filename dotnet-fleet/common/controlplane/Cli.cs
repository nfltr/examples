// The operator CLI (dispatch, bench), the same in app/ and
// with-nfltr/.
// The operator side: POST /dispatch and check what came back. Exit 0 when
// every agent's outcomes, in order (repeats collapsed), are --expect.
static class Cli
{
    static readonly System.Text.Json.JsonSerializerOptions Json = new(System.Text.Json.JsonSerializerDefaults.Web);

    public static async Task<int> Run(string verb, IConfiguration a)
    {
        using var http = new HttpClient { BaseAddress = new Uri(a["admin"] ?? "http://127.0.0.1:5080"), Timeout = Timeout.InfiniteTimeSpan };
        var agents = (a["agents"] ?? throw new ArgumentException("--agents is required")).Split(',');
        var req = new DispatchRequest(a["via"] ?? "mapping", agents, a["action"] ?? "collect-diagnostics",
            int.Parse(a["steps"] ?? "5"), int.Parse(a["step-ms"] ?? "100"), int.Parse(a["deadline-ms"] ?? "0"), a["fresh"] == "true");
        return verb == "bench" ? await Bench(http, req, int.Parse(a["n"] ?? "50")) : await Dispatch(http, req, (a["expect"] ?? "ok").Split(','), int.Parse(a["retry-s"] ?? "0"));
    }

    static async Task<Outcome[]> Post(HttpClient http, DispatchRequest req)
    {
        using var resp = await http.PostAsJsonAsync("/dispatch", req);
        resp.EnsureSuccessStatusCode();
        return (await resp.Content.ReadFromJsonAsync<Outcome[]>())!;
    }

    static async Task<int> Dispatch(HttpClient http, DispatchRequest req, string[] expect, int retryS)
    {
        var until = DateTime.UtcNow.AddSeconds(retryS);
        var history = req.Agents.ToDictionary(x => x, _ => new List<string>());
        var pending = req.Agents;
        while (true)
        {
            foreach (var o in await Post(http, req with { Agents = pending }))
            {
                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(o, Json));
                var h = history[o.Agent];
                if (h.Count == 0 || h[^1] != o.Status) h.Add(o.Status);
            }
            pending = pending.Where(x => history[x][^1] != "ok").ToArray();
            if (pending.Length == 0 || DateTime.UtcNow > until) break;
            await Task.Delay(250); // the application's own retry policy
        }
        var bad = history.Where(h => !h.Value.SequenceEqual(expect)).Select(h => $"{h.Key}: {string.Join(",", h.Value)}").ToList();
        Console.WriteLine(bad.Count == 0 ? $"PASS {req.Via}: {string.Join(",", expect)}" : $"FAIL {req.Via}: want {string.Join(",", expect)}; {string.Join("; ", bad)}");
        return bad.Count == 0 ? 0 : 1;
    }

    // Latency per agent over n sequential calls (the server's measurement of
    // each call, without the operator API's own hop), after n untimed calls
    // that warm up the JIT and the channels.
    static async Task<int> Bench(HttpClient http, DispatchRequest req, int n)
    {
        var ms = req.Agents.ToDictionary(x => x, _ => new List<double>());
        for (var i = -n; i < n; i++)
            foreach (var agent in req.Agents)
                foreach (var o in await Post(http, req with { Agents = [agent] }))
                {
                    if (o.Status != "ok")
                    {
                        Console.WriteLine($"FAIL {agent}: {o.Status} {o.Output}");
                        return 1;
                    }
                    if (i >= 0) ms[agent].Add(o.Ms);
                }
        foreach (var (agent, v) in ms)
        {
            v.Sort();
            double P(double q) => v[(int)Math.Min(v.Count - 1, Math.Ceiling(q * v.Count) - 1)];
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { via = req.Via, agent, fresh = req.Fresh, steps = req.Steps, n, p50_ms = Math.Round(P(0.5), 2), p95_ms = Math.Round(P(0.95), 2), max_ms = Math.Round(v[^1], 2) }));
        }
        return 0;
    }
}
