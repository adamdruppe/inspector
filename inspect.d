import terminal;

import arsd.script;
import arsd.http2;

import std.stdio;

string lastLine;
HttpClient client;

void main() {
	auto terminal = Terminal(ConsoleOutputType.cellular);
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

	auto client = new HttpClient();
	.client = client;

	auto lineGetter = new LineGetter(&terminal, "json-inspect");
	scope(exit) lineGetter.dispose();
	terminal.moveTo(0, terminal.height - 1);
	lineGetter.startGettingLine();

	version(sample)
	drawInspectionWindow(&terminal, json!q{
		"test":"string!",
		"int":100,
		"float":1.35,
		"array":[1,2,3],
		"object": {
			"str":"foo",
			"subnumber":12,
			"longarray": [1,2,3,4,5,6,7,8,9,1,2,3,4,5,5,6,4,23,343,234,234,23,423,3]
		},
		"null":null,
		"bool1":true,
		"bool2":false,
		"objarr":[
			{"id":12,"name":"twelve"},
			{"id":12,"name":"twelve"},
			{"id":12,"name":"twelve"}
		],
		"rls":"really long string that wouldn't be easy to ready becasuse it would wrap and fill up all the nonsense and hate the hatred"
	});

	bool running = true;

	var globals = var.emptyObject;

	globals.inspectionStack = [];
	globals.pushInspection = delegate var(var i) {
		globals.inspectionStack ~= i;
		globals.inspecting = i;
		return i;
	};

	globals.popInspection = delegate var() {
		var i = globals.inspectionStack[$-1];
		globals.inspectionStack = globals.inspectionStack[0 .. $-1];
		return i;
	};

	globals["get"] = delegate var(string path) {
		auto request = client.navigateTo(Uri(path));
		request.send();
		return var(request.waitForCompletion());
	};

	void handleEvent(InputEvent event) {
		switch(event.type) {
			default:
				try
				if(!lineGetter.workOnLine(event)) {
					auto line = lineGetter.finishGettingLine();
					lastLine = line;
					try {
						drawInspectionWindow(&terminal, globals.pushInspection()(interpret(line, globals)));
					} catch(Exception e) {
						drawInspectionWindow(&terminal, var(e.toString()));
					}
					terminal.moveTo(0, terminal.height - 1);
					lineGetter.startGettingLine();
				}
				catch(Exception e)
					running = false;
		}
	}

	while(running) {
		auto event = input.nextEvent();
		handleEvent(event);
	}

}

void drawInspectionWindow(Terminal* terminal, var inspecting) {
	terminal.clear();

	terminal.write("[<<] [>>]  || ");
	terminal.write(client.location);
	terminal.write(" || ");
	terminal.writeln(lastLine);

	foreach(i; 0 .. terminal.width)
		terminal.write("-");

	//terminal.moveTo(0, 2);

	drawItem(terminal, inspecting, 0);

	terminal.flush();
}

// This pretty prints a JSON object and remembers where the items are on screen so you
// can click on them too.
void drawItem(Terminal* terminal, var inspecting, int indentLevel, bool child = false) {
	void indent() {
		terminal.write("\n");
		foreach(i; 0 .. indentLevel)
			terminal.write("  ");
	}

	final switch(inspecting.payloadType) {
		case var.Type.Object:
			if(inspecting == null)
				terminal.write("null");
			else {
				terminal.write("{");
				indentLevel++;
				foreach(k, v; inspecting) {
					indent();
					terminal.write(k);
					terminal.write(": ");
					drawItem(terminal, v, indentLevel, true);
				}
				indentLevel--;
				indent();
				terminal.write("}");
			}
		break;
		case var.Type.String:
			auto disp = inspecting.toString();
			if(indentLevel && disp.length > 40)
				disp = disp[0 .. 40] ~ "[...]";
			terminal.write("\"", disp, "\"");
		break;
		case var.Type.Array:
			terminal.write("[");
			if(!indentLevel) {
				indentLevel++;
				foreach(idx, item; inspecting) {
					indent();
					drawItem(terminal, item, indentLevel + 1);
				}
				indentLevel--;
				indent();
			}
			else if(inspecting.length < 5)
				foreach(idx, item; inspecting) {
					if(idx)
						terminal.write(", ");
					drawItem(terminal, item, indentLevel + 1);
				}
			else
				terminal.writef("... %d items ...", inspecting.length);
			terminal.write("]");
		break;
		case var.Type.Integral:
		case var.Type.Floating:
		case var.Type.Boolean:
		case var.Type.Function:
			terminal.write(inspecting);
	}
}

/*
	inspect(obj)
		loads that object into the inspection window
	expand("path")
		expands the given object path in the inspection window


	http_client
		maintains cookies
		relative url


	http_transaction
		request
			method
			path
			queryArgs
			cookies
			rawHeaders (a array of strings)
			headers (an object)
			rawContent (a string)
			content (parsed into an object according to content-type)
		response
			headers
			cookies
			rawContent
			content
*/
