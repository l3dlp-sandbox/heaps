package hxd.impl;
import hxd.impl.Allocator;

@:allow(hxd.impl.CacheAllocator)
private class Cache<T> {
	var available : Array<T> = [];
	var disposed : Array<T> = [];
	public var lastUse : Float = haxe.Timer.stamp();
	public var onDispose : T -> Void;

	public function new( ?dispose ) {
		onDispose = dispose;
	}
	public inline function get() {
		var b = available.pop();
		if( available.length == 0 ) lastUse = haxe.Timer.stamp();
		return b;
	}

	public inline function put(v) {
		disposed.push(v);
	}

	public function nextFrame() {
		while( available.length > 0 )
			disposed.push(available.pop());
		var tmp = available;
		available = disposed;
		disposed = tmp;
	}

	public function gc() {
		var b = available.pop();
		if( b == null ) b = disposed.pop();
		if( b == null ) return false;
		if( onDispose != null ) onDispose(b);
		return true;
	}
}

class CacheAllocator extends Allocator {

	public var currentFrame = -1;
	var buffers = new Map<Int,Cache<h3d.Buffer>>();
	var indexBuffers = new Map<Int,Cache<h3d.Indexes>>();

	var lastGC = haxe.Timer.stamp();
	/**
	 * How long do we keep some buffer than hasn't been used in memory (in seconds, default 60)
	**/
	public var maxKeepTime = 60.;

	override function allocBuffer(vertices:Int, format:hxd.BufferFormat, flags:BufferFlags=Dynamic):h3d.Buffer {
		if( vertices >= 65536 ) {
			switch ( flags ) {
			case UniformReadWrite:
			default: throw "assert";
			}
		}
		checkFrame();
		var id = flags.toInt() | (format.uid << 3) | (vertices << 16);
		var c = buffers.get(id);
		if( c != null ) {
			var b = c.get();
			if( b != null ) return b;
		}
		checkGC();
		return super.allocBuffer(vertices,format,flags);
	}

	override function disposeBuffer(b:h3d.Buffer) {
		if( b.isDisposed() ) return;
		var f = b.flags;
		var flags = f.has(UniformBuffer) ? UniformDynamic : (f.has(Dynamic) ? Dynamic : Static);
		var id = flags.toInt() | (b.format.uid << 3) | (b.vertices << 16);
		var c = buffers.get(id);
		if( c == null ) {
			c = new Cache(function(b:h3d.Buffer) b.dispose());
			buffers.set(id, c);
		}
		c.put(b);
		checkGC();
	}

	override function allocIndexBuffer( count : Int, is32 : Bool = false ) {
		var id = count << 1 + (is32 ? 1 : 0);
		checkFrame();
		var c = indexBuffers.get(id);
		if( c != null ) {
			var i = c.get();
			if( i != null ) return i;
		}
		checkGC();
		return super.allocIndexBuffer(count, is32);
	}

	override function disposeIndexBuffer( i : h3d.Indexes ) {
		if( i.isDisposed() ) return;
		var is32 = cast(i, h3d.Buffer).format.strideBytes == 4;
		var id = i.count << 1 + (is32 ? 1 : 0);
		var c = indexBuffers.get(id);
		if( c == null ) {
			c = new Cache(function(i:h3d.Indexes) i.dispose());
			indexBuffers.set(id, c);
		}
		c.put(i);
		checkGC();
	}

	override function onContextLost() {
		buffers = new Map();
		indexBuffers = new Map();
	}

	public function checkFrame() {
		if( currentFrame == hxd.Timer.frameCount )
			return;
		currentFrame = hxd.Timer.frameCount;
		for( b in buffers )
			b.nextFrame();
		for( b in indexBuffers )
			b.nextFrame();
	}

	public function checkGC() {
		var t = haxe.Timer.stamp();
		if( t - lastGC > maxKeepTime * 0.1 ) gc();
	}

	public function gc() {
		var now = haxe.Timer.stamp();
		for( b in buffers.keys() ) {
			var c = buffers.get(b);
			if( now - c.lastUse > maxKeepTime && !c.gc() )
				buffers.remove(b);
		}
		for( b in indexBuffers.keys() ) {
			var c = indexBuffers.get(b);
			if( now - c.lastUse > maxKeepTime && !c.gc() )
				indexBuffers.remove(b);
		}
		lastGC = now;
	}

	public function clear() {
		for ( c in buffers ) {
			for ( b in c.available ) {
				b.dispose();
			}
			for ( b in c.disposed ) {
				b.dispose();
			}
		}
		for ( c in indexBuffers ) {
			for ( b in c.available ) {
				b.dispose();
			}
			for ( b in c.disposed ) {
				b.dispose();
			}
		}
		buffers = [];
		indexBuffers = [];
	}

}
