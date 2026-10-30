import express from "express";
 
const app = express();
const port = Number(process.env.PORT || 3000);
 
app.disable("x-powered-by");
app.use(express.json());
 
app.get("/health", (_req, res) => {
res.status(200).json({
status: "ok",
service: "air-course-development-middleware"
});
});
 
app.listen(port, "0.0.0.0", () => {
console.log(`AIR middleware listening on port ${port}`);
});
